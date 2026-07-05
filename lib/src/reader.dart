// The reader isolate. It owns all backpressure: it drains the pipes
// continuously (so a writer can never block), assembles whole lines, keeps a
// bounded ring (drop-oldest, counted), writes the durable mirror file, and
// ships the main isolate credit-bounded batches.
//
// Main → reader control travels over a self-pipe (not a SendPort), because this
// loop blocks in poll() and never services an isolate event loop: byte 1 = a
// spent-batch credit, byte 0 = stop. Reader → main is the SendPort.

import 'dart:collection';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'captured_line.dart';
import 'line_assembler.dart';
import 'posix.dart';

/// Spawn payload. All fields are isolate-sendable.
final class ReaderConfig {
  const ReaderConfig({
    required this.outReadFd,
    required this.errReadFd,
    required this.controlReadFd,
    required this.toMain,
    required this.backlogLines,
    required this.mirrorFd,
    this.initialCredit = 8,
    this.batchMaxLines = 512,
    this.pollTimeoutMs = 50,
  });

  final int outReadFd;
  final int errReadFd;
  final int controlReadFd;
  final SendPort toMain;
  final int backlogLines;

  /// Mirror-file fd, already opened (and validated) by the controller on the
  /// main isolate — so a bad path throws at start() instead of killing this
  /// isolate. fds are process-global; the reader owns and closes it.
  final int? mirrorFd;
  final int initialCredit;
  final int batchMaxLines;
  final int pollTimeoutMs;
}

/// A batch of captured lines plus the reader's cumulative drop counters. Sent to
/// the main isolate; `lines == null` with [done] true is the final message.
final class ReaderBatch {
  const ReaderBatch(this.lines, this.droppedLines, this.droppedBytes,
      {this.done = false});
  final List<CapturedLine>? lines;
  final int droppedLines;
  final int droppedBytes;
  final bool done;
}

/// Control-pipe bytes: main → reader flow control (no SendPort, since the reader
/// blocks in poll() and can't service an event loop).
const int ctrlStop = 0; // shut down
const int ctrlCredit = 1; // one spent-batch credit replenished

/// Isolate entry point.
void readerMain(ReaderConfig cfg) {
  _Reader(cfg).run();
}

class _Reader {
  _Reader(this.cfg);
  final ReaderConfig cfg;

  late final LineAssembler _outAsm =
      LineAssembler((b) => _emitLine(b, StdStream.out));
  late final LineAssembler _errAsm =
      LineAssembler((b) => _emitLine(b, StdStream.err));
  // A ListQueue so drop-oldest and batch extraction are O(1) per line — a
  // plain List's removeAt(0)/removeRange(0, n) shifts the whole backlog on
  // every operation once the ring is saturated.
  final _ring = ListQueue<CapturedLine>();
  final _mirrorBuf = BytesBuilder();

  int _credit = 0;
  int _droppedLines = 0;
  int _droppedBytes = 0;
  bool _outDone = false;
  bool _errDone = false;
  bool _stop = false;
  int? _mirrorFd;

  void run() {
    _credit = cfg.initialCredit;
    // Throws if O_NONBLOCK doesn't verifiably take (→ onError → readerError):
    // the drain loop is only correct on non-blocking fds.
    setNonBlocking(cfg.outReadFd);
    setNonBlocking(cfg.errReadFd);
    setNonBlocking(cfg.controlReadFd);
    _mirrorFd = cfg.mirrorFd;

    final pfds = malloc<PollFd>(3);
    final readBuf = malloc<Uint8>(64 * 1024);
    var pollFailures = 0;
    try {
      while (true) {
        pfds[0]
          ..fd = cfg.outReadFd
          ..events = pollIn
          ..revents = 0;
        pfds[1]
          ..fd = cfg.errReadFd
          ..events = pollIn
          ..revents = 0;
        pfds[2]
          ..fd = cfg.controlReadFd
          ..events = pollIn
          ..revents = 0;

        final rc = poll(pfds, 3, cfg.pollTimeoutMs);
        if (rc < 0) {
          // EINTR is retried inside poll(); anything else here is exotic
          // (EAGAIN under kernel pressure). Tolerate transients, but a poll
          // that fails persistently would otherwise turn this loop into a hot
          // spin — die loudly instead (→ onError → readerError on the main
          // isolate).
          if (++pollFailures > 100) {
            throw StdioCaptureException(
                'reader poll() failing persistently: errno=$errno');
          }
          continue;
        }
        pollFailures = 0;

        // Control first — a stop should win even amid a data storm. POLLNVAL
        // (fd closed under us in a teardown race) is included everywhere so a
        // dead fd resolves to done/stop instead of spinning the loop.
        const wake = pollIn | pollHup | pollErr | pollNval;
        if (pfds[2].revents & wake != 0) {
          _drainControl(cfg.controlReadFd, readBuf);
        }
        if (!_outDone && pfds[0].revents & wake != 0) {
          _drainStream(cfg.outReadFd, StdStream.out, _outAsm, readBuf);
        }
        if (!_errDone && pfds[1].revents & wake != 0) {
          _drainStream(cfg.errReadFd, StdStream.err, _errAsm, readBuf);
        }

        _flushMirror();
        _shipBatches();

        if (_stop || (_outDone && _errDone && _ring.isEmpty)) {
          // Final non-blocking drain: the stop byte can race ahead of a poll
          // wake, so data may still be buffered in the pipes. Read whatever's
          // left before finishing (the write ends are already closed).
          if (!_outDone) {
            _drainStream(cfg.outReadFd, StdStream.out, _outAsm, readBuf);
          }
          if (!_errDone) {
            _drainStream(cfg.errReadFd, StdStream.err, _errAsm, readBuf);
          }
          _finish();
          break;
        }
      }
    } finally {
      malloc.free(pfds);
      malloc.free(readBuf);
      if (_mirrorFd != null) closeFd(_mirrorFd!);
    }
  }

  /// Drain a pipe read-end fully (it's non-blocking) into whole lines via [asm].
  void _drainStream(
      int fd, StdStream stream, LineAssembler asm, Pointer<Uint8> buf) {
    while (true) {
      final n = readFd(fd, buf, 64 * 1024);
      if (n > 0) {
        // Safe to hand the assembler a view over the reused native buffer:
        // add() copies as it goes and retains nothing after it returns (the
        // LineAssembler contract) — the buffer isn't touched again until the
        // next read().
        asm.add(buf.asTypedList(n));
      } else if (n == 0) {
        asm.flush(); // EOF: all write ends closed
        _markDone(stream);
        return;
      } else if (errno == eagain) {
        return; // fully drained
      } else {
        // Hard error (e.g. EBADF after a teardown race): the fd will never
        // recover, so treat it as end-of-stream rather than spinning on it.
        asm.flush();
        _markDone(stream);
        return;
      }
    }
  }

  void _markDone(StdStream stream) {
    if (stream == StdStream.out) {
      _outDone = true;
    } else {
      _errDone = true;
    }
  }

  void _emitLine(Uint8List bytes, StdStream stream) {
    // Mirror gets EVERYTHING (durable log is independent of the UI ring).
    if (_mirrorFd != null) {
      _mirrorBuf
        ..add(bytes)
        ..addByte(0x0A);
    }
    final line = CapturedLine(rawBytes: bytes, stream: stream, at: DateTime.now());
    _ring.add(line);
    if (_ring.length > cfg.backlogLines) {
      final dropped = _ring.removeFirst();
      _droppedLines++;
      _droppedBytes += dropped.rawBytes.length;
    }
  }

  void _flushMirror() {
    if (_mirrorFd == null || _mirrorBuf.isEmpty) return;
    fdWriteAll(_mirrorFd!, _mirrorBuf.takeBytes());
  }

  /// Ship up to [batchMaxLines]-sized batches while we hold send credit.
  void _shipBatches() {
    while (_credit > 0 && _ring.isNotEmpty) {
      final take = _ring.length < cfg.batchMaxLines
          ? _ring.length
          : cfg.batchMaxLines;
      final batch = List<CapturedLine>.generate(
          take, (_) => _ring.removeFirst(),
          growable: false);
      cfg.toMain.send(ReaderBatch(batch, _droppedLines, _droppedBytes));
      _credit--;
    }
  }

  void _drainControl(int fd, Pointer<Uint8> buf) {
    while (true) {
      final n = readFd(fd, buf, 64 * 1024);
      if (n > 0) {
        for (var i = 0; i < n; i++) {
          if (buf[i] == ctrlStop) {
            _stop = true;
          } else if (buf[i] == ctrlCredit) {
            _credit++;
          }
        }
      } else if (n == 0) {
        // EOF: the control write end closed ⇒ the main isolate is gone or
        // tearing down. Same conclusion for a hard read error. Either way the
        // reader must wind down — nobody is listening anymore.
        _stop = true;
        return;
      } else {
        if (errno != eagain) _stop = true;
        return;
      }
    }
  }

  /// Final message: flush partials, drain the ring regardless of credit (bounded
  /// by backlog), then send Done.
  void _finish() {
    _outAsm.flush();
    _errAsm.flush();
    _flushMirror();
    if (_ring.isNotEmpty) {
      cfg.toMain.send(ReaderBatch(
          List<CapturedLine>.of(_ring), _droppedLines, _droppedBytes));
      _ring.clear();
    }
    cfg.toMain.send(ReaderBatch(null, _droppedLines, _droppedBytes, done: true));
  }
}
