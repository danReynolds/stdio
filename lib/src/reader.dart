// The reader isolate. It owns all backpressure: it drains the pipes
// continuously (so a writer can never block), assembles whole lines, keeps a
// bounded ring (drop-oldest, counted), writes the durable mirror file, and
// ships the main isolate credit-bounded batches.
//
// Main → reader control travels over a self-pipe (not a SendPort), because this
// loop blocks in poll() and never services an isolate event loop: byte 1 = a
// spent-batch credit, byte 0 = stop. Reader → main is the SendPort.

import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'captured_line.dart';
import 'posix.dart';

/// Spawn payload. All fields are isolate-sendable.
final class ReaderConfig {
  const ReaderConfig({
    required this.outReadFd,
    required this.errReadFd,
    required this.controlReadFd,
    required this.toMain,
    required this.backlogLines,
    required this.mirrorPath,
    this.initialCredit = 8,
    this.batchMaxLines = 512,
    this.pollTimeoutMs = 50,
  });

  final int outReadFd;
  final int errReadFd;
  final int controlReadFd;
  final SendPort toMain;
  final int backlogLines;
  final String? mirrorPath;
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

  final _outPartial = BytesBuilder();
  final _errPartial = BytesBuilder();
  final _ring = <CapturedLine>[];
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
    setNonBlocking(cfg.outReadFd);
    setNonBlocking(cfg.errReadFd);
    setNonBlocking(cfg.controlReadFd);
    if (cfg.mirrorPath != null) {
      _mirrorFd = openForWrite(cfg.mirrorPath!, append: true);
    }

    final pfds = malloc<PollFd>(3);
    final readBuf = malloc<Uint8>(64 * 1024);
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

        poll(pfds, 3, cfg.pollTimeoutMs);

        // Control first — a stop should win even amid a data storm.
        if (pfds[2].revents & (pollIn | pollHup) != 0) {
          _drainControl(cfg.controlReadFd, readBuf);
        }
        if (!_outDone && pfds[0].revents & (pollIn | pollHup | pollErr) != 0) {
          _drainStream(cfg.outReadFd, StdStream.out, _outPartial, readBuf);
        }
        if (!_errDone && pfds[1].revents & (pollIn | pollHup | pollErr) != 0) {
          _drainStream(cfg.errReadFd, StdStream.err, _errPartial, readBuf);
        }

        _flushMirror();
        _shipBatches();

        if (_stop || (_outDone && _errDone && _ring.isEmpty)) {
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

  /// Drain a pipe read-end fully (it's non-blocking) into whole lines.
  void _drainStream(int fd, StdStream stream, BytesBuilder partial,
      Pointer<Uint8> buf) {
    while (true) {
      final n = readFd(fd, buf, 64 * 1024);
      if (n > 0) {
        // Copy out of the reused native buffer immediately — [partial] and any
        // sublist views must not alias memory the next read() will overwrite.
        _assemble(Uint8List.fromList(buf.asTypedList(n)), stream, partial);
      } else if (n == 0) {
        // EOF: the write ends are all closed. Flush any trailing partial.
        _flushPartial(stream, partial);
        if (stream == StdStream.out) {
          _outDone = true;
        } else {
          _errDone = true;
        }
        return;
      } else {
        if (errno == eagain) return; // fully drained
        return; // hard error — treat as done-ish; loop exit handles it
      }
    }
  }

  /// Split [chunk] on 0x0A into lines, carrying [partial] across reads. `\n`
  /// never occurs inside a multi-byte UTF-8 sequence, so this is codepoint-safe.
  void _assemble(Uint8List chunk, StdStream stream, BytesBuilder partial) {
    var start = 0;
    for (var i = 0; i < chunk.length; i++) {
      if (chunk[i] == 0x0A) {
        partial.add(Uint8List.sublistView(chunk, start, i));
        _emitLine(partial.takeBytes(), stream);
        start = i + 1;
      }
    }
    if (start < chunk.length) {
      partial.add(Uint8List.sublistView(chunk, start));
    }
  }

  void _flushPartial(StdStream stream, BytesBuilder partial) {
    if (partial.isNotEmpty) _emitLine(partial.takeBytes(), stream);
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
      final dropped = _ring.removeAt(0);
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
      final batch = _ring.sublist(0, take);
      _ring.removeRange(0, take);
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
      } else {
        return; // EOF or EAGAIN
      }
    }
  }

  /// Final message: flush partials, drain the ring regardless of credit (bounded
  /// by backlog), then send Done.
  void _finish() {
    _flushPartial(StdStream.out, _outPartial);
    _flushPartial(StdStream.err, _errPartial);
    _flushMirror();
    if (_ring.isNotEmpty) {
      cfg.toMain.send(ReaderBatch(
          List<CapturedLine>.of(_ring), _droppedLines, _droppedBytes));
      _ring.clear();
    }
    cfg.toMain.send(ReaderBatch(null, _droppedLines, _droppedBytes, done: true));
  }
}
