import 'dart:async';
import 'dart:collection';
import 'dart:io' as io;
import 'dart:isolate';
import 'dart:typed_data';

import 'captured_line.dart';
import 'line_assembler.dart';
import 'posix.dart';
import 'reader.dart';
import 'terminal_sink.dart';

/// Result of a scoped [StdioCapture.collect].
final class Captured {
  Captured(this.lines);

  /// Every captured line, tagged and in delivery order (stdout/stderr exact
  /// within each stream; cross-stream order approximate — §6.4 of the RFC).
  final List<CapturedLine> lines;

  late final String out = _join(StdStream.out);
  late final String err = _join(StdStream.err);

  String _join(StdStream s) =>
      lines.where((l) => l.stream == s).map((l) => l.text).join('\n');
}

/// A live redirect of fd 1/2 straight to a file (no capture, no draining).
final class StdioRedirect {
  StdioRedirect._(this._saved1, this._saved2);
  final int _saved1;
  final int _saved2;
  var _stopped = false;

  /// Restore fd 1/2 to their original targets. Idempotent.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    dup2(_saved1, 1);
    dup2(_saved2, 2);
    closeFd(_saved1);
    closeFd(_saved2);
    StdioCapture._busy = false;
  }
}

/// File-descriptor-level capture of stdout/stderr — including native/FFI and
/// inherited-subprocess output. See the class methods for the three entry
/// points. POSIX only.
final class StdioCapture {
  StdioCapture._({
    required int savedFd,
    required int savedErrFd,
    required int outWriteFd,
    required int errWriteFd,
    required int outReadFd,
    required int errReadFd,
    required int controlReadFd,
    required int controlWriteFd,
    required Isolate isolate,
    required ReceivePort fromReader,
    required this.terminal,
    required int backlogLines,
  })  : _savedFd = savedFd,
        _savedErrFd = savedErrFd,
        _outWriteFd = outWriteFd,
        _errWriteFd = errWriteFd,
        _outReadFd = outReadFd,
        _errReadFd = errReadFd,
        _controlReadFd = controlReadFd,
        _controlWriteFd = controlWriteFd,
        _isolate = isolate,
        _fromReader = fromReader,
        _backlogLines = backlogLines;

  // A single process-global fd redirect at a time (§6.2). Main-isolate scoped.
  static bool _busy = false;

  final int _savedFd; // dup of the original fd 1 — also the render target
  final int _savedErrFd; // dup of the original fd 2 (they can differ: `2>file`)
  final int _outWriteFd;
  final int _errWriteFd;
  final int _outReadFd;
  final int _errReadFd;
  final int _controlReadFd;
  final int _controlWriteFd;
  final Isolate _isolate;
  final ReceivePort _fromReader;
  final int _backlogLines;

  /// The real terminal, for rendering (the saved dup of fd 1). Invalid once
  /// [stop] completes — the controller closes the saved fd.
  final TerminalSink terminal;

  /// The same terminal as a concrete [io.Stdout], for consumers (a TUI driver)
  /// that require the concrete type rather than a [TerminalSink]/[IOSink].
  late final io.Stdout terminalStdout = StdoutTerminalSink(_savedFd);

  final _out = StreamController<CapturedLine>.broadcast();
  final _err = StreamController<CapturedLine>.broadcast();
  final _combined = StreamController<CapturedLine>.broadcast();
  final _history = ListQueue<CapturedLine>();
  final _readerDone = Completer<void>();

  int _droppedLines = 0;
  int _droppedBytes = 0;
  Future<List<CapturedLine>>? _finishing; // memoized teardown
  bool _closed = false; // final snapshot taken; late lines are discarded
  Object? _readerError;

  /// Optional best-effort source tag for the in-process merged stream.
  String? Function(CapturedLine line)? _classify;

  /// stdout lines only (exact within-stream order). Broadcast — pair with
  /// [history] for output produced before you subscribed. Note that a *paused*
  /// subscription buffers unboundedly (Dart stream semantics): don't pause a
  /// slow consumer, sample [history] instead.
  Stream<CapturedLine> get stdout => _out.stream;

  /// stderr lines only (exact within-stream order).
  Stream<CapturedLine> get stderr => _err.stream;

  /// Both streams, interleaved (approximate cross-stream order). Each line
  /// carries its [CapturedLine.stream] tag.
  StreamSubscription<CapturedLine> listen(
    void Function(CapturedLine line)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _combined.stream.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  /// A snapshot of retained lines (bounded to `backlogLines`, drop-oldest).
  List<CapturedLine> get history => List<CapturedLine>.unmodifiable(_history);

  /// Lines dropped under backpressure (in the reader isolate).
  int get droppedLines => _droppedLines;
  int get droppedBytes => _droppedBytes;

  bool get isActive => _finishing == null;

  /// Non-null if the reader isolate died with an error. Line delivery has
  /// stopped when this is set; [stop] still restores fd 1/2 normally.
  Object? get readerError => _readerError;

  /// Redirect fd 1/2 into the capture and drain off-isolate. Throws [StateError]
  /// if a capture/redirect is already active (fd redirection is process-global).
  static Future<StdioCapture> start({
    int backlogLines = 4096,
    io.File? mirrorToFile,
    String? Function(CapturedLine line)? classify,
  }) async {
    if (backlogLines < 1) {
      throw ArgumentError.value(
          backlogLines, 'backlogLines', 'must be >= 1 (bounds retention AND '
          'the reader ring — 0 would silently drop every line)');
    }
    if (_busy) {
      throw StateError(
          'stdio_capture: a capture/redirect is already active. fd redirection '
          'is process-global — stop the current one first.');
    }
    _busy = true;

    // Setup ordering: do everything fallible FIRST, redirect fd 1/2 LAST, so
    // the window where a failure requires un-redirecting is just Isolate.spawn.
    final opened = <int>[];
    var savedOut = -1;
    var savedErr = -1;
    var redirected = false;
    ReceivePort? fromReader;
    try {
      savedOut = dup(1);
      if (savedOut < 0) throw StdioCaptureException('dup(1) failed: errno=$errno');
      opened.add(savedOut);
      setCloexec(savedOut);
      // fd 2 gets its own save — the two can point at different places
      // (`prog 2>err.log`), so restoring both from a dup of fd 1 would silently
      // re-route stderr on stop.
      savedErr = dup(2);
      if (savedErr < 0) throw StdioCaptureException('dup(2) failed: errno=$errno');
      opened.add(savedErr);
      setCloexec(savedErr);

      final (outR, outW) = makePipe();
      opened
        ..add(outR)
        ..add(outW);
      setCloexec(outR);
      setCloexec(outW);
      final (errR, errW) = makePipe();
      opened
        ..add(errR)
        ..add(errW);
      setCloexec(errR);
      setCloexec(errW);
      final (ctrlR, ctrlW) = makePipe();
      opened
        ..add(ctrlR)
        ..add(ctrlW);
      setCloexec(ctrlR);
      setCloexec(ctrlW);

      // Open the mirror HERE, not in the reader: a bad path throws at start()
      // (rolled back cleanly) instead of killing the reader isolate silently.
      // fds are process-global, so passing the number across isolates is sound;
      // the reader owns and closes it.
      int? mirrorFd;
      if (mirrorToFile != null) {
        mirrorFd = openForWrite(mirrorToFile.path, append: true);
        opened.add(mirrorFd);
        setCloexec(mirrorFd);
      }

      fromReader = ReceivePort();

      // Redirect. dup2 clears CLOEXEC on the target, so fd 1/2 stay inheritable.
      dup2(outW, 1);
      dup2(errW, 2);
      redirected = true;

      // onError/onExit route to the SAME port as the data batches, on purpose:
      // Dart guarantees FIFO delivery within one port but NOT across ports, so
      // a separate exit port's notification can overtake still-queued batches
      // (observed: a fast stop() snapshotting before the final lines landed).
      // On one port the death notice can never pass the data. An error arrives
      // as a List [error, stack], exit as null — both distinguishable from a
      // ReaderBatch in _onReaderMessage.
      final isolate = await Isolate.spawn(
        readerMain,
        ReaderConfig(
          outReadFd: outR,
          errReadFd: errR,
          controlReadFd: ctrlR,
          toMain: fromReader.sendPort,
          backlogLines: backlogLines,
          mirrorFd: mirrorFd,
        ),
        onError: fromReader.sendPort,
        onExit: fromReader.sendPort,
        debugName: 'stdio_capture.reader',
      );

      final cap = StdioCapture._(
        savedFd: savedOut,
        savedErrFd: savedErr,
        outWriteFd: outW,
        errWriteFd: errW,
        outReadFd: outR,
        errReadFd: errR,
        controlReadFd: ctrlR,
        controlWriteFd: ctrlW,
        isolate: isolate,
        fromReader: fromReader,
        terminal: FdTerminalSink(savedOut),
        backlogLines: backlogLines,
      );
      cap._classify = classify;
      fromReader.listen(cap._onReaderMessage);
      return cap;
    } catch (e) {
      // Rollback: un-redirect only if we actually redirected, then release
      // everything we opened.
      if (redirected) {
        dup2(savedOut, 1);
        dup2(savedErr, 2);
      }
      for (final fd in opened) {
        closeFd(fd);
      }
      fromReader?.close();
      _busy = false;
      rethrow;
    }
  }

  void _onReaderMessage(dynamic msg) {
    if (msg is! ReaderBatch) {
      // Not a batch ⇒ a lifecycle notification (same port as the data, so it
      // can never overtake it): a List [error, stack] from onError, or null
      // from onExit. Either way no more lines are coming — a dead reader must
      // not be silent, nor leave stop() waiting out its drain timeout.
      if (msg is List && msg.isNotEmpty) _readerError ??= msg.first;
      if (!_readerDone.isCompleted) _readerDone.complete();
      return;
    }
    _droppedLines = msg.droppedLines;
    _droppedBytes = msg.droppedBytes;
    final lines = msg.lines;
    if (lines != null && lines.isNotEmpty) {
      for (final l in lines) {
        _emit(l);
      }
      _sendControl(ctrlCredit); // replenish the reader's send credit
    }
    if (msg.done && !_readerDone.isCompleted) _readerDone.complete();
  }

  /// Add a line to history + the streams, applying the classifier if the line is
  /// untagged. Shared by the reader path and subprocess adoption.
  void _emit(CapturedLine l) {
    if (_closed) return; // a late adopt()-stream event after the snapshot
    if (l.source == null && _classify != null) l.source = _classify!(l);
    _history.add(l);
    if (_history.length > _backlogLines) _history.removeFirst();
    if (!_combined.isClosed) _combined.add(l);
    final c = l.stream == StdStream.out ? _out : _err;
    if (!c.isClosed) c.add(l);
  }

  /// Spawn a child, tagging its stdout/stderr with [source] and merging them
  /// into this capture. Started in `normal` mode (separate pipes) so its lines
  /// can be tagged — an `inheritStdio` child would flow through fd 1/2 already,
  /// untagged.
  ///
  /// Delivery for tagged children rides the MAIN isolate's event loop (unlike
  /// fd 1/2, which the reader isolate drains even when main stalls) — so a
  /// stalled main isolate backpressures the child instead of this process.
  Future<io.Process> startProcess(String executable, List<String> arguments,
      {required String source,
      String? workingDirectory,
      Map<String, String>? environment}) async {
    final proc = await io.Process.start(executable, arguments,
        workingDirectory: workingDirectory, environment: environment);
    adopt(proc, source: source);
    return proc;
  }

  /// Tag an already-started (`normal`-mode) child's output with [source] and
  /// merge it. Only safe if nothing else has listened to [child]'s streams yet.
  void adopt(io.Process child, {required String source}) {
    _pipeChild(child.stdout, StdStream.out, source);
    _pipeChild(child.stderr, StdStream.err, source);
  }

  void _pipeChild(Stream<List<int>> stream, StdStream s, String source) {
    final asm = LineAssembler((bytes) => _emit(CapturedLine(
        rawBytes: bytes, stream: s, at: DateTime.now(), source: source)));
    stream.listen(
      (chunk) => asm.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk)),
      onDone: asm.flush,
    );
  }

  void _sendControl(int byte) {
    try {
      fdWriteAll(_controlWriteFd, [byte]);
    } catch (_) {
      // control pipe closed during teardown — ignore
    }
  }

  /// Restore fd 1/2 and tear down. Idempotent and concurrent-safe: every call
  /// awaits the same teardown. See §7.3 for the ordering. After this returns,
  /// [terminal]/[terminalStdout] are invalid (their fd is closed).
  Future<void> stop() => _finish();

  Future<List<CapturedLine>> _finish() => _finishing ??= _doFinish();

  Future<List<CapturedLine>> _doFinish() async {
    // Flush Dart's own buffered stdout/stderr into the pipe BEFORE we restore,
    // or those bytes would surface on the terminal after the swap.
    try {
      await io.stdout.flush();
    } catch (_) {}
    try {
      await io.stderr.flush();
    } catch (_) {}

    // (1) restore fd 1/2 — each from its OWN saved dup — so no new bytes enter
    // the pipes.
    dup2(_savedFd, 1);
    dup2(_savedErrFd, 2);
    // (2) close the write ends → reader hits EOF; also signal stop for the case
    // where an inherited child still holds a pipe write end.
    closeFd(_outWriteFd);
    closeFd(_errWriteFd);
    _sendControl(ctrlStop);
    // (3) wait for the reader to drain + finish (bounded — a stuck child that
    // never EOFs won't hang us forever; a dead reader completes this early via
    // the onError/onExit ports).
    await _readerDone.future
        .timeout(const Duration(seconds: 2), onTimeout: () {});

    final snapshot = List<CapturedLine>.of(_history);
    _closed = true;

    // (4) close read ends + control + saved fds; kill the isolate (a no-op if
    // it exited; the backstop if it's stuck); close ports + streams.
    closeFd(_outReadFd);
    closeFd(_errReadFd);
    closeFd(_controlReadFd);
    closeFd(_controlWriteFd);
    closeFd(_savedFd);
    closeFd(_savedErrFd);
    _isolate.kill(priority: Isolate.immediate);
    _fromReader.close();
    await _combined.close();
    await _out.close();
    await _err.close();
    _busy = false;
    return snapshot;
  }

  /// Scoped capture — runs [body] with fd 1/2 captured and returns everything,
  /// restoring after (INCLUDING when [body] throws — the redirect is released
  /// and the original exception propagates). Built on [start]; process-global
  /// (§6.2).
  static Future<Captured> collect(FutureOr<void> Function() body) async {
    final cap = await StdioCapture.start();
    var lines = const <CapturedLine>[];
    try {
      await body();
    } finally {
      // No settling delay needed: stop() closes the pipe write ends, and the
      // reader drains to EOF — everything written before this point is
      // guaranteed captured.
      lines = await cap._finish();
    }
    return Captured(lines);
  }

  /// Direct redirect of fd 1/2 to a file — no pipe, no draining, faithful merged
  /// order. For headless nodes that just want native noise in a log.
  static Future<StdioRedirect> divertToFile(io.File file,
      {bool append = true}) async {
    if (_busy) {
      throw StateError('stdio_capture: a capture/redirect is already active.');
    }
    _busy = true;
    final opened = <int>[];
    try {
      final saved1 = dup(1);
      if (saved1 < 0) throw StdioCaptureException('dup(1) failed: errno=$errno');
      opened.add(saved1);
      setCloexec(saved1);
      final saved2 = dup(2);
      if (saved2 < 0) throw StdioCaptureException('dup(2) failed: errno=$errno');
      opened.add(saved2);
      setCloexec(saved2);
      final fileFd = openForWrite(file.path, append: append);
      dup2(fileFd, 1);
      dup2(fileFd, 2);
      closeFd(fileFd); // fd 1/2 hold the file now; the extra fd isn't needed
      return StdioRedirect._(saved1, saved2);
    } catch (e) {
      // Nothing was redirected yet if openForWrite threw (the only fallible
      // step after the dups) — just release the saved fds.
      for (final fd in opened) {
        closeFd(fd);
      }
      _busy = false;
      rethrow;
    }
  }
}
