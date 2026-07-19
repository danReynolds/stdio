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
import 'exception.dart';
import 'line_assembler.dart';
import 'posix.dart';

/// Spawn payload. All fields are isolate-sendable.
final class ReaderConfig {
  const ReaderConfig({
    required this.outReadFd,
    required this.errReadFd,
    required this.controlReadFd,
    required this.toMain,
    required this.historyLines,
    required this.mirrorFd,
    this.savedOutFd,
    this.savedErrFd,
    this.maxLineBytes = 64 * 1024,
    this.initialCredit = 8,
    this.batchMaxLines = 512,
    this.pollTimeoutMs = 50,
  });

  final int outReadFd;
  final int errReadFd;
  final int controlReadFd;
  final SendPort toMain;
  final int historyLines;

  /// Mirror-file fd, already opened (and validated) by the controller on the
  /// main isolate — so a bad path throws at start() instead of killing this
  /// isolate. fds are process-global; the reader owns and closes it.
  final int? mirrorFd;

  /// Saved dups of the ORIGINAL fd 1/2 to mirror raw captured chunks back to,
  /// byte-transparent and split-intact — for sessions whose original
  /// descriptors carry no frames (a served/agent app writing to a parent's
  /// pipe), so the parent keeps receiving output live while the capture
  /// feeds the in-app log. Best-effort and NEVER blocking (this loop's
  /// contract): a full pipe carries a bounded backlog, then drops — counted
  /// in [ReaderBatch.mirrorDroppedBytes], a DEDICATED counter (these are
  /// mirror-channel bytes, not capture-stream lines; the capture itself is
  /// unaffected); a dead fd disables the mirror. The controller owns and
  /// closes these fds — the reader only writes.
  final int? savedOutFd;
  final int? savedErrFd;
  final int maxLineBytes;
  final int initialCredit;
  final int batchMaxLines;
  final int pollTimeoutMs;
}

/// A batch of captured lines plus the reader's cumulative drop counters. Sent to
/// the main isolate; `lines == null` with [done] true is the final message.
final class ReaderBatch {
  const ReaderBatch(
      this.lines, this.droppedLines, this.droppedBytes, this.mirrorDroppedBytes,
      {this.done = false});
  final List<CapturedLine>? lines;
  final int droppedLines;
  final int droppedBytes;

  /// Cumulative bytes the saved-fd mirror channel could not deliver (backlog
  /// overflow past the bounded carry, or backlog discarded when a dead fd
  /// disabled the mirror). A separate channel from the line counters above.
  final int mirrorDroppedBytes;
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

  late final LineAssembler _outAsm = LineAssembler(
      (b) => _emitLine(b, StdStream.out),
      maxLineBytes: cfg.maxLineBytes);
  late final LineAssembler _errAsm = LineAssembler(
      (b) => _emitLine(b, StdStream.err),
      maxLineBytes: cfg.maxLineBytes);
  // A ListQueue so drop-oldest and batch extraction are O(1) per line — a
  // plain List's removeAt(0)/removeRange(0, n) shifts the whole backlog on
  // every operation once the ring is saturated.
  final _ring = ListQueue<CapturedLine>();
  final _mirrorBuf = BytesBuilder();

  int _credit = 0;
  int _droppedLines = 0;
  int _droppedBytes = 0;
  int _mirrorDroppedBytes = 0;
  bool _outDone = false;
  bool _errDone = false;
  bool _stop = false;
  int? _mirrorFd;

  // Saved-fd mirror state (see ReaderConfig.savedOutFd). Per-stream carry of
  // bytes the (non-blocking) saved fd wouldn't take yet; bounded so a parent
  // that stops draining costs memory once, then drops — never a blocked
  // reader. Retries ride the poll cadence (≤ pollTimeoutMs latency).
  static const int _savedCarryCap = 256 * 1024;
  int? _savedOutFd;
  int? _savedErrFd;
  final _savedOutCarry = BytesBuilder(copy: true);
  final _savedErrCarry = BytesBuilder(copy: true);

  void run() {
    _credit = cfg.initialCredit;
    // Throws if O_NONBLOCK doesn't verifiably take (→ onError → readerError):
    // the drain loop is only correct on non-blocking fds.
    setNonBlocking(cfg.outReadFd);
    setNonBlocking(cfg.errReadFd);
    setNonBlocking(cfg.controlReadFd);
    _mirrorFd = cfg.mirrorFd;
    // The saved-fd mirror must never block this loop; the flag lives on the
    // shared open file description, but in mirror mode nothing else writes
    // that description (the app's fd 1/2 were dup2'd away to the capture
    // pipes). Failure to set it just disables the mirror — capture still
    // works.
    _savedOutFd = _prepSavedFd(cfg.savedOutFd);
    _savedErrFd = _prepSavedFd(cfg.savedErrFd);

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
            throw StdioException(
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

        _pumpSavedCarry(); // retry any mirror bytes a full pipe deferred
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
        final view = buf.asTypedList(n);
        // Raw-chunk mirror to the saved fd: byte-transparent (partial lines,
        // \r progress — everything passes through unassembled) and BEFORE
        // line assembly so the parent's view is unmodified. _mirrorToSaved
        // copies what it must keep; the view dies with this iteration.
        _mirrorToSaved(stream, view);
        asm.add(view);
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
    // seq is a placeholder here: the session stamps the real one on the main
    // isolate as the line enters the transcript (so it's monotonic across
    // every source, children included).
    final line = CapturedLine(
        bytes: bytes, stream: stream, at: DateTime.now(), seq: -1);
    _ring.add(line);
    if (_ring.length > cfg.historyLines) {
      final dropped = _ring.removeFirst();
      _droppedLines++;
      _droppedBytes += dropped.bytes.length;
    }
  }

  void _flushMirror() {
    if (_mirrorFd == null || _mirrorBuf.isEmpty) return;
    fdWriteAll(_mirrorFd!, _mirrorBuf.takeBytes());
  }

  // --- saved-fd mirror (never blocks; see ReaderConfig.savedOutFd) ---------

  int? _prepSavedFd(int? fd) {
    if (fd == null) return null;
    try {
      setNonBlocking(fd);
      return fd;
    } on Object {
      return null; // can't guarantee non-blocking writes — mirror disabled
    }
  }

  void _mirrorToSaved(StdStream stream, Uint8List chunk) {
    final fd = stream == StdStream.out ? _savedOutFd : _savedErrFd;
    if (fd == null) return;
    final carry = stream == StdStream.out ? _savedOutCarry : _savedErrCarry;
    if (carry.isNotEmpty) {
      // A backlog exists — preserve byte order: queue behind it and pump.
      _carryAdd(carry, chunk);
      _pumpSaved(stream);
      return;
    }
    final wrote = fdWriteBest(fd, chunk);
    if (wrote < 0) {
      _mirrorDroppedBytes += chunk.length;
      _disableSaved(stream);
    } else if (wrote < chunk.length) {
      _carryAdd(carry, Uint8List.sublistView(chunk, wrote));
    }
  }

  void _carryAdd(BytesBuilder carry, Uint8List bytes) {
    final room = _savedCarryCap - carry.length;
    if (room <= 0) {
      // Stalled parent: bounded backlog, then drop — counted, never blocked.
      _mirrorDroppedBytes += bytes.length;
      return;
    }
    if (bytes.length <= room) {
      carry.add(bytes);
    } else {
      carry.add(Uint8List.sublistView(bytes, 0, room));
      _mirrorDroppedBytes += bytes.length - room;
    }
  }

  void _pumpSaved(StdStream stream) {
    final fd = stream == StdStream.out ? _savedOutFd : _savedErrFd;
    if (fd == null) return;
    final carry = stream == StdStream.out ? _savedOutCarry : _savedErrCarry;
    if (carry.isEmpty) return;
    final pending = carry.takeBytes();
    final wrote = fdWriteBest(fd, pending);
    if (wrote < 0) {
      _mirrorDroppedBytes += pending.length;
      _disableSaved(stream);
    } else if (wrote < pending.length) {
      carry.add(Uint8List.sublistView(pending, wrote));
    }
  }

  void _pumpSavedCarry() {
    _pumpSaved(StdStream.out);
    _pumpSaved(StdStream.err);
  }

  void _disableSaved(StdStream stream) {
    // The undelivered backlog is dropped with the channel — count it.
    if (stream == StdStream.out) {
      _savedOutFd = null;
      _mirrorDroppedBytes += _savedOutCarry.length;
      _savedOutCarry.clear();
    } else {
      _savedErrFd = null;
      _mirrorDroppedBytes += _savedErrCarry.length;
      _savedErrCarry.clear();
    }
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
      cfg.toMain.send(
          ReaderBatch(batch, _droppedLines, _droppedBytes, _mirrorDroppedBytes));
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
    _pumpSavedCarry(); // last best-effort push of mirror backlog
    _flushMirror();
    if (_ring.isNotEmpty) {
      cfg.toMain.send(ReaderBatch(List<CapturedLine>.of(_ring), _droppedLines,
          _droppedBytes, _mirrorDroppedBytes));
      _ring.clear();
    }
    cfg.toMain.send(ReaderBatch(
        null, _droppedLines, _droppedBytes, _mirrorDroppedBytes,
        done: true));
  }
}
