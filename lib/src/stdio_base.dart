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

/// The transcript of a capture — returned by [StdioCapture.capture] and
/// [StdioCapture.stop].
final class Captured {
  Captured(this.lines);

  /// Every captured line, tagged and in delivery order (stdout/stderr exact
  /// within each stream; cross-stream order approximate — the two-pipe
  /// tag/order trade).
  final List<CapturedLine> lines;

  /// The stdout lines joined with `'\n'` — for assertions like
  /// `cap.out.contains(...)`.
  late final String out = _join(StdStream.out);

  /// The stderr lines joined with `'\n'`.
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
/// inherited-subprocess output. POSIX only.
///
/// Three entry points, following the `Process.start`/`Process.run` pattern:
/// [start] returns a live session handle, [capture] is the scoped one-shot,
/// and [redirectToFile] reroutes fd 1/2 with no capture at all.
///
/// ```dart
/// final capture = await StdioCapture.start(historyLines: 8192);
///
/// capture.history.forEach(paint);            // lines from before you subscribed
/// final sub = capture.output.listen(paint);  // live from now on
/// capture.terminal.writeln('frame…');        // draw to the REAL terminal
///
/// final result = await capture.stop();       // restore fd 1/2, full transcript
/// ```
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
    required int historyLines,
    required int maxLineBytes,
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
        _historyLines = historyLines,
        _maxLineBytes = maxLineBytes;

  // A single process-global fd redirect at a time. Main-isolate scoped.
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
  final int _historyLines;
  final int _maxLineBytes;

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

  /// Both streams interleaved; each line carries its [CapturedLine.stream]
  /// tag. Cross-stream order is approximate (the two-pipe tag/order trade —
  /// [redirectToFile] is the exact-merged-order mode). Broadcast, same
  /// no-pause caveat as [stdout].
  Stream<CapturedLine> get output => _combined.stream;

  /// A snapshot of the retained lines, both streams, delivery order — at most
  /// `historyLines` of them (beyond that the oldest were dropped and counted
  /// in [droppedLines]/[droppedBytes]).
  List<CapturedLine> get history => List<CapturedLine>.unmodifiable(_history);

  /// Lines dropped under backpressure (in the reader isolate).
  int get droppedLines => _droppedLines;
  int get droppedBytes => _droppedBytes;

  /// True until [stop] is first called. Note a capture can be active but
  /// degraded — see [readerError].
  bool get isActive => _finishing == null;

  /// Non-null if the reader isolate died mid-session. When that happens the
  /// line streams close (listeners get onDone) and delivery stops; [stop]
  /// still restores fd 1/2 normally.
  Object? get readerError => _readerError;

  /// Redirect fd 1/2 into this capture until [stop], returning the live
  /// session handle everything else is called on.
  ///
  /// [historyLines] bounds how many lines the capture retains — the [history]
  /// snapshot and the internal buffer feeding it. Beyond that, the oldest
  /// lines are dropped and counted in [droppedLines]/[droppedBytes]. It does
  /// NOT limit the live streams: [stdout]/[stderr]/[output] subscribers see
  /// every line that isn't dropped under overload.
  ///
  /// [mirrorToFile] appends every captured line to a durable file, written by
  /// the reader isolate itself — so the log survives a stalled main isolate
  /// and (up to the in-flight tail) an abrupt exit. An unopenable path throws
  /// here, with the redirect rolled back.
  ///
  /// [classify] runs once per untagged line; a non-null return becomes that
  /// line's [CapturedLine.source].
  ///
  /// [maxLineBytes] bounds the in-progress line, so a writer that never emits
  /// a newline can't grow memory: longer runs are delivered split into
  /// cap-sized pieces (split, not dropped).
  ///
  /// Throws [StateError] if a capture/redirect is already active — fd
  /// redirection is process-global, one at a time.
  static Future<StdioCapture> start({
    int historyLines = 4096,
    int maxLineBytes = 64 * 1024,
    io.File? mirrorToFile,
    String? Function(CapturedLine line)? classify,
  }) async {
    if (historyLines < 1) {
      throw ArgumentError.value(historyLines, 'historyLines', 'must be >= 1');
    }
    if (maxLineBytes < 1024) {
      throw ArgumentError.value(maxLineBytes, 'maxLineBytes', 'must be >= 1024');
    }
    if (_busy) {
      throw StateError(
          'stdio: a capture/redirect is already active. fd redirection '
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
          historyLines: historyLines,
          maxLineBytes: maxLineBytes,
          mirrorFd: mirrorFd,
        ),
        onError: fromReader.sendPort,
        onExit: fromReader.sendPort,
        debugName: 'stdio.reader',
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
        historyLines: historyLines,
        maxLineBytes: maxLineBytes,
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
      if (_finishing == null) {
        // The reader died OUTSIDE a stop(): fds are still redirected but
        // nothing is draining. Be loud — record why and close the line
        // streams so listeners observe onDone instead of silence. stop()
        // still restores normally.
        _readerError ??=
            StdioCaptureException('reader isolate exited unexpectedly');
        _combined.close();
        _out.close();
        _err.close();
      }
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

  /// Add a line to history + the streams, applying the classifier if the line
  /// is untagged. Shared by the reader path and subprocess adoption.
  void _emit(CapturedLine l) {
    if (_closed) return; // a late adopt()-stream event after the snapshot
    var line = l;
    if (line.source == null && _classify != null) {
      final tag = _classify!(line);
      if (tag != null) {
        // CapturedLine is immutable; tagging takes a copy.
        line = CapturedLine(
            bytes: line.bytes, stream: line.stream, at: line.at, source: tag);
      }
    }
    _history.add(line);
    if (_history.length > _historyLines) _history.removeFirst();
    if (!_combined.isClosed) _combined.add(line);
    final c = line.stream == StdStream.out ? _out : _err;
    if (!c.isClosed) c.add(line);
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
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false}) async {
    final proc = await io.Process.start(executable, arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        includeParentEnvironment: includeParentEnvironment,
        runInShell: runInShell);
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
    final asm = LineAssembler(
        (bytes) => _emit(CapturedLine(
            bytes: bytes, stream: s, at: DateTime.now(), source: source)),
        maxLineBytes: _maxLineBytes);
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

  bool _paused = false;

  /// Whether the capture is currently [pause]d.
  bool get isPaused => _paused;

  /// Temporarily point fd 1/2 back at the real terminal without tearing the
  /// session down — the reader, pipes, streams, [history], and
  /// [terminal]/[terminalStdout] all stay live; writes during the pause go
  /// straight to the terminal and are NOT captured.
  ///
  /// This is the terminal-handoff primitive for TUIs: suspend capture, spawn
  /// `$EDITOR`/a pager with `ProcessStartMode.inheritStdio` (the child
  /// inherits the *real* descriptors), then [resume] when it exits. Dart's
  /// buffered stdout/stderr are flushed into the pipe first, so bytes written
  /// before the pause stay part of the capture.
  ///
  /// No-op if already paused. Throws [StateError] after [stop].
  Future<void> pause() async {
    _checkLive();
    if (_paused) return;
    // Bytes written up to the completion of these flushes belong to the
    // capture (fd 1/2 still point at the pipes); the pause takes effect when
    // this future completes.
    try {
      await io.stdout.flush();
    } catch (_) {}
    try {
      await io.stderr.flush();
    } catch (_) {}
    // Re-check after the async gap: a concurrent stop() may have begun
    // teardown while we awaited — its restore already happened and the saved
    // fds may be closed, so redirecting now would corrupt descriptor state.
    _checkLive();
    _dup2Checked(_savedFd, 1, 'pause');
    _dup2Checked(_savedErrFd, 2, 'pause');
    _paused = true;
  }

  /// Re-redirect fd 1/2 into the capture after a [pause]. Terminal-bound
  /// buffered bytes are flushed first, so pause-window output lands on the
  /// terminal rather than leaking into the capture.
  ///
  /// No-op if not paused. Throws [StateError] after [stop].
  Future<void> resume() async {
    _checkLive();
    if (!_paused) return;
    try {
      await io.stdout.flush();
    } catch (_) {}
    try {
      await io.stderr.flush();
    } catch (_) {}
    // Re-check after the async gap (see pause()): stop() closes the pipe
    // write ends, so a late re-redirect would target dead descriptors.
    _checkLive();
    _dup2Checked(_outWriteFd, 1, 'resume');
    _dup2Checked(_errWriteFd, 2, 'resume');
    _paused = false;
  }

  void _checkLive() {
    if (_closed || _finishing != null) {
      throw StateError('stdio: capture is stopped.');
    }
  }

  static void _dup2Checked(int from, int to, String op) {
    if (dup2(from, to) < 0) {
      throw StdioCaptureException(
          'stdio: $op dup2($from, $to) failed: errno=$errno');
    }
  }

  /// Restore fd 1/2 and tear down, returning the full transcript — the same
  /// [Captured] a scoped [capture] call yields. Idempotent and
  /// concurrent-safe: every call awaits the same teardown and gets the same
  /// snapshot. After this returns, [terminal]/[terminalStdout] are invalid
  /// (their fd is closed). Teardown order: restore fd 1/2, EOF the reader,
  /// drain to completion (bounded), then close — nothing in flight is lost
  /// and no writer sees EPIPE. Safe to call while [pause]d (the restore is
  /// idempotent).
  Future<Captured> stop() async => Captured(await _finish());

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
    _paused = false;

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

  /// Scoped capture: the window is exactly the execution of [body].
  ///
  /// Desugars to `start()` → `await body()` → `stop()` in a finally — so fd
  /// 1/2 are restored even when [body] throws (the exception then
  /// propagates), and everything written before [body]'s future completes is
  /// guaranteed in the result (the teardown drains the pipes to EOF).
  ///
  /// The `Process.run` to [start]'s `Process.start`: use this when the
  /// capture doesn't outlive one call — tests, wrapping a noisy init.
  static Future<Captured> capture(FutureOr<void> Function() body) async {
    final cap = await StdioCapture.start();
    var lines = const <CapturedLine>[];
    try {
      await body();
    } finally {
      lines = await cap._finish();
    }
    return Captured(lines);
  }

  /// Reroute fd 1/2 straight to [file] — a *move*, not a tee: the file
  /// replaces the terminal, nothing appears on screen, and the bytes never
  /// come back into your program (no streams, no history, no isolate — the
  /// kernel does all the work). It's `prog >log 2>&1` done from inside the
  /// process, reversed by [StdioRedirect.stop].
  ///
  /// The one mode with EXACT merged ordering (both fds share one file
  /// description), and it keeps working even if every isolate stalls. For
  /// headless services that just need native noise in a log; if you want to
  /// *observe* output, use [start] (its `mirrorToFile` is the tee-like
  /// duplicate).
  static Future<StdioRedirect> redirectToFile(io.File file,
      {bool append = true}) async {
    if (_busy) {
      throw StateError('stdio: a capture/redirect is already active.');
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
