import 'dart:async';
import 'dart:collection';
import 'dart:io' as io;
import 'dart:isolate';
import 'dart:typed_data';

import 'captured_line.dart';
import 'exception.dart';
import 'line_assembler.dart';
import 'posix.dart';
import 'reader.dart';
import 'terminal_sink.dart';

/// The result of a capture — returned by [Stdio.capture] (where [value] is
/// what the body returned) and [Stdio.stop] (where `T` is `void`).
final class Captured<T> {
  /// Creates a result. Constructed by the package; public so tests can build
  /// fixture values.
  Captured(this.value, this.lines,
      {required this.droppedLines, required this.droppedBytes});

  /// What the [Stdio.capture] body returned (`void` for [Stdio.stop]).
  final T value;

  /// The retained transcript: every line still in history at stop time,
  /// tagged and in delivery order (stdout/stderr exact within each stream;
  /// cross-stream order approximate — the two-pipe tag/order trade). At most
  /// `historyLines` of them — [droppedLines] counts what is missing.
  final List<CapturedLine> lines;

  /// Lines missing from [lines]: dropped in the reader isolate under
  /// backpressure, plus evicted from the bounded history ring once it passed
  /// `historyLines` (evicted lines were still seen by live stream
  /// subscribers).
  final int droppedLines;

  /// The bytes of the lines counted in [droppedLines].
  final int droppedBytes;

  /// The stdout lines joined with `'\n'` — for assertions like
  /// `cap.out.contains(...)`.
  late final String out = _join(StdStream.out);

  /// The stderr lines joined with `'\n'`.
  late final String err = _join(StdStream.err);

  String _join(StdStream s) =>
      lines.where((l) => l.stream == s).map((l) => l.text).join('\n');
}

/// A child process whose tagged output is merged into a capture — returned by
/// [Stdio.startProcess].
final class CapturedProcess {
  CapturedProcess._(this.process, this.drained);

  /// The underlying process — `exitCode`, `kill()`, `stdin` all live here.
  final io.Process process;

  /// Completes when every line of the child's stdout/stderr has been
  /// delivered into the capture (both streams closed and their partial-line
  /// tails flushed). `process.exitCode` completing does NOT imply this — the
  /// final pipe contents ride the event loop afterwards — so await this
  /// before a `stop()` that must include the child's full output.
  final Future<void> drained;
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
    Stdio._busy = false;
  }
}

/// Test seam: kill [session]'s reader isolate abruptly, as if it crashed.
///
/// Deliberately NOT exported from `package:stdio/stdio.dart` (the test suite
/// reaches it via a direct `src/` import) — it exists so the reader-death
/// degradation path can be exercised deterministically.
void debugKillReaderForTest(Stdio session) =>
    session._isolate.kill(priority: Isolate.immediate);

/// File-descriptor-level capture of stdout/stderr — including native/FFI and
/// inherited-subprocess output. POSIX only.
///
/// Three entry points, following the `Process.start`/`Process.run` pattern:
/// [start] returns a live session handle, [capture] is the scoped one-shot,
/// and [redirectToFile] reroutes fd 1/2 with no capture at all.
///
/// ```dart
/// final capture = await Stdio.start(historyLines: 8192);
///
/// capture.history.forEach(paint);            // lines from before you subscribed
/// final sub = capture.output.listen(paint);  // live from now on
/// capture.terminal.writeln('frame…');        // draw to the REAL terminal
///
/// final result = await capture.stop();       // restore fd 1/2 + transcript
/// ```
final class Stdio {
  Stdio._({
    required int savedFd,
    required int savedErrFd,
    required int savedFdFlags,
    required int savedErrFdFlags,
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
    required bool mirrorToOriginal,
  })  : _savedFd = savedFd,
        _savedErrFd = savedErrFd,
        _savedFdFlags = savedFdFlags,
        _savedErrFdFlags = savedErrFdFlags,
        _outWriteFd = outWriteFd,
        _errWriteFd = errWriteFd,
        _outReadFd = outReadFd,
        _errReadFd = errReadFd,
        _controlReadFd = controlReadFd,
        _controlWriteFd = controlWriteFd,
        _isolate = isolate,
        _fromReader = fromReader,
        _historyLines = historyLines,
        _maxLineBytes = maxLineBytes,
        _mirrorToOriginal = mirrorToOriginal;

  // A single process-global fd redirect at a time. Main-isolate scoped.
  static bool _busy = false;

  /// True while any capture ([start]/[capture]) or redirect ([redirectToFile])
  /// holds fd 1/2 — for coordination between components that might each want
  /// one (a logger and a TUI driver, say), so they can check before starting.
  /// Purely advisory: an uncoordinated second [start] still fails loud with a
  /// [StateError]. (Named `anyActive` because [isActive] is the per-session
  /// getter.)
  static bool get anyActive => _busy;

  final int _savedFd; // dup of the original fd 1 — also the render target
  final int _savedErrFd; // dup of the original fd 2 (they can differ: `2>file`)
  // F_GETFL snapshots taken at start(), BEFORE the reader isolate could touch
  // the descriptions (its mirror-to-original prep sets O_NONBLOCK, and the
  // flag lives on the open file DESCRIPTION — shared with the fd 1/2 we hand
  // back on stop(), and with the parent shell when the target is the tty).
  // Restored in _doFinish on every exit path. Negative = snapshot failed,
  // skip the restore.
  final int _savedFdFlags;
  final int _savedErrFdFlags;
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
  // Whether the reader also writes the saved fds (the mirror-to-original
  // channel) — teardown's timeout path must not close fds a wedged reader may
  // still write to.
  final bool _mirrorToOriginal;

  /// The real terminal — wherever fd 1 originally pointed (the saved dup) —
  /// for rendering to the screen while everything else is captured.
  ///
  /// A [StdoutTerminalSink], so it is BOTH a [TerminalSink] (size, `isatty`,
  /// raw fd) and a concrete [io.Stdout] — it drops into APIs that require
  /// either, with one shared, mutable [StdoutTerminalSink.encoding]. Invalid
  /// once [stop] completes (the controller closes the saved fd).
  final StdoutTerminalSink terminal;

  /// Where fd 2 originally pointed (the saved dup). The two can differ
  /// (`2>file`, a parent that pipes them separately), so a consumer tee-ing
  /// captured lines back out — e.g. a served TUI forwarding output to its
  /// host process while also buffering it — can preserve the stdout/stderr
  /// split instead of folding stderr into the stdout pipe. Invalid once
  /// [stop] completes.
  late final StdoutTerminalSink terminalStderr =
      StdoutTerminalSink(_savedErrFd);

  final _out = StreamController<CapturedLine>.broadcast();
  final _err = StreamController<CapturedLine>.broadcast();
  final _combined = StreamController<CapturedLine>.broadcast();
  final _history = ListQueue<CapturedLine>();
  final _readerDone = Completer<void>();

  // Reader-side drops (cumulative, reported with each batch) and main-isolate
  // history evictions are separate events; [droppedLines]/[droppedBytes]
  // report their sum — "lines missing from history".
  int _readerDroppedLines = 0;
  int _readerDroppedBytes = 0;
  int _evictedLines = 0;
  int _evictedBytes = 0;
  int _mirrorDroppedBytes = 0;
  int _seq = 0; // next CapturedLine.seq, stamped in _emit
  Future<List<CapturedLine>>? _finishing; // memoized teardown
  bool _closed = false; // final snapshot taken; late lines are discarded
  bool _readerDied = false; // distinct from _readerError: classify errors land
  // there too, but only an actual reader death degrades the session's fds.
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
  ///
  /// Gap-free start-up recipe: read [history] and subscribe here in the SAME
  /// synchronous turn — no `await` between them — and no line can land in the
  /// gap. If you must subscribe after an `await`, stitch with
  /// [CapturedLine.seq]: skip stream lines whose `seq` is at or below the
  /// last history line's.
  Stream<CapturedLine> get output => _combined.stream;

  /// A snapshot of the retained lines, both streams, delivery order — at most
  /// `historyLines` of them (beyond that the oldest were evicted and counted
  /// in [droppedLines]/[droppedBytes]).
  ///
  /// Taking this snapshot and subscribing to [output] in the same synchronous
  /// turn observes every line exactly once; across an `await`, dedupe on
  /// [CapturedLine.seq] (see [output]).
  List<CapturedLine> get history => List<CapturedLine>.unmodifiable(_history);

  /// Lines missing from [history] (and so from the final transcript): the sum
  /// of lines dropped in the reader isolate under backpressure (never
  /// delivered anywhere) and lines evicted from the bounded history ring
  /// (which live [stdout]/[stderr]/[output] subscribers DID still see).
  int get droppedLines => _readerDroppedLines + _evictedLines;

  /// The bytes of the lines counted in [droppedLines].
  int get droppedBytes => _readerDroppedBytes + _evictedBytes;

  /// Bytes the `mirrorToOriginal` channel could not deliver: its target
  /// stopped draining and the bounded backlog overflowed, or the target died
  /// and the mirror was disabled (its remaining backlog counts too, after
  /// which the disabled channel stops counting). A DEDICATED counter — mirror
  /// bytes are a separate channel from the captured-line counters above, and
  /// mirror drops never affect the capture itself. Always 0 unless
  /// `mirrorToOriginal: true`.
  int get mirrorDroppedBytes => _mirrorDroppedBytes;

  /// True until [stop] is first called. Note a capture can be active but
  /// degraded — see [readerError].
  bool get isActive => _finishing == null;

  /// Non-null once the capture has degraded: the reader isolate died
  /// mid-session, or a `classify` callback threw (first cause retained).
  ///
  /// On a reader death the line streams close (listeners get onDone),
  /// delivery stops, and fd 1/2 are restored immediately so the app's writes
  /// cannot wedge on the undrained pipes; [stop] still tears down normally.
  /// Note the value for a reader death is the STRINGIFIED error (that is what
  /// `Isolate.onError` delivers across the isolate boundary), not the
  /// original exception object; a classify error is the thrown object itself.
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
  /// here, with the redirect rolled back. Caveat: the path is opened for
  /// writing synchronously at start() — pointing it at a FIFO that has no
  /// reader blocks start() forever (POSIX `open(O_WRONLY)` semantics on
  /// FIFOs); mirror to regular files.
  ///
  /// [mirrorToOriginal] additionally mirrors every captured raw chunk back to
  /// wherever fd 1/2 ORIGINALLY pointed (the saved dups) — byte-transparent
  /// and split-intact: partial lines, `\r` progress bars, everything passes
  /// through unassembled, keeping the stdout/stderr split. This is for
  /// sessions whose original descriptors carry no rendered frames (a
  /// served/agent app writing to a parent's pipe), so the parent keeps
  /// receiving output live while the capture feeds the in-app view — where
  /// [mirrorToFile] mirrors *assembled lines* to a file. Written on the
  /// reader isolate and never blocking: a full target carries a bounded
  /// backlog, then drops (counted in [mirrorDroppedBytes]); a dead target
  /// disables the mirror. Do not combine with rendering to [terminal] — both
  /// write the same descriptors. The never-block contract keeps `O_NONBLOCK`
  /// set on the saved descriptions for the session's lifetime ([stop] restores
  /// the original flags), which makes [pause] handoffs a poor fit — see the
  /// caveat on [pause].
  ///
  /// [classify] runs once per untagged line; a non-null return becomes that
  /// line's [CapturedLine.source]. A [classify] that throws is treated as
  /// returning null; the first error is surfaced once on [readerError].
  ///
  /// [maxLineBytes] bounds the in-progress line, so a writer that never emits
  /// a newline can't grow memory: longer runs are delivered split into
  /// cap-sized pieces (split, not dropped).
  ///
  /// Ranges: [historyLines] must be >= 1 and [maxLineBytes] >= 1024;
  /// out-of-range values throw [ArgumentError].
  ///
  /// Call from the main isolate only: fd redirection is process-global, but
  /// the active-session guard (and the whole controller) is isolate-local — a
  /// second isolate calling this would fight over fd 1/2 unguarded.
  ///
  /// Throws [StateError] if a capture/redirect is already active — fd
  /// redirection is process-global, one at a time ([anyActive] is the
  /// advisory probe).
  static Future<Stdio> start({
    int historyLines = 4096,
    int maxLineBytes = 64 * 1024,
    io.File? mirrorToFile,
    bool mirrorToOriginal = false,
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
      if (savedOut < 0) throw StdioException('dup(1) failed: errno=$errno');
      opened.add(savedOut);
      setCloexec(savedOut);
      // fd 2 gets its own save — the two can point at different places
      // (`prog 2>err.log`), so restoring both from a dup of fd 1 would silently
      // re-route stderr on stop.
      savedErr = dup(2);
      if (savedErr < 0) throw StdioException('dup(2) failed: errno=$errno');
      opened.add(savedErr);
      setCloexec(savedErr);
      // Snapshot the file-status flags NOW, before the reader isolate can
      // modify the (shared) descriptions — restored in stop()'s teardown.
      final savedOutFlags = fdGetFlags(savedOut);
      final savedErrFlags = fdGetFlags(savedErr);

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
          // The mirror-to-original channel (see [mirrorToOriginal]'s doc
          // above). The controller still owns and closes the saved fds on
          // stop(); the reader only writes them.
          savedOutFd: mirrorToOriginal ? savedOut : null,
          savedErrFd: mirrorToOriginal ? savedErr : null,
        ),
        onError: fromReader.sendPort,
        onExit: fromReader.sendPort,
        debugName: 'stdio.reader',
      );

      final cap = Stdio._(
        savedFd: savedOut,
        savedErrFd: savedErr,
        savedFdFlags: savedOutFlags,
        savedErrFdFlags: savedErrFlags,
        outWriteFd: outW,
        errWriteFd: errW,
        outReadFd: outR,
        errReadFd: errR,
        controlReadFd: ctrlR,
        controlWriteFd: ctrlW,
        isolate: isolate,
        fromReader: fromReader,
        terminal: StdoutTerminalSink(savedOut),
        historyLines: historyLines,
        maxLineBytes: maxLineBytes,
        mirrorToOriginal: mirrorToOriginal,
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
      _readerDied = true;
      if (msg is List && msg.isNotEmpty) _readerError ??= msg.first;
      if (!_readerDone.isCompleted) _readerDone.complete();
      if (_finishing == null) {
        // The reader died OUTSIDE a stop(): fds are still redirected but
        // nothing is draining. Be loud — record why and close the line
        // streams so listeners observe onDone instead of silence. stop()
        // still restores normally.
        _readerError ??=
            StdioException('reader isolate exited unexpectedly');
        // Restore fd 1/2 IMMEDIATELY: the pipes have no drainer anymore, so
        // the app's next ~64 KiB of writes would wedge the main isolate in a
        // blocking write(). (If we're paused, fd 1/2 already point at the
        // saved fds — the dup2 is a harmless no-op.) readerError + the closed
        // streams remain the degradation signal; stop() re-runs the restore
        // idempotently and finishes the teardown.
        dup2(_savedFd, 1);
        dup2(_savedErrFd, 2);
        if (_savedFdFlags >= 0) fdSetFlags(_savedFd, _savedFdFlags);
        if (_savedErrFdFlags >= 0) fdSetFlags(_savedErrFd, _savedErrFdFlags);
        _combined.close();
        _out.close();
        _err.close();
      }
      return;
    }
    _readerDroppedLines = msg.droppedLines;
    _readerDroppedBytes = msg.droppedBytes;
    _mirrorDroppedBytes = msg.mirrorDroppedBytes;
    final lines = msg.lines;
    if (lines != null && lines.isNotEmpty) {
      for (final l in lines) {
        _emit(l);
      }
      _sendControl(ctrlCredit); // replenish the reader's send credit
    }
    if (msg.done && !_readerDone.isCompleted) _readerDone.complete();
  }

  /// Add a line to history + the streams, stamping its [CapturedLine.seq] and
  /// applying the classifier if the line is untagged. Shared by the reader
  /// path and subprocess adoption.
  void _emit(CapturedLine l) {
    if (_closed) return; // a late adopt()-stream event after the snapshot
    var source = l.source;
    if (source == null && _classify != null) {
      try {
        source = _classify!(l);
      } catch (e) {
        // A throwing classifier must not escape into the reader-port handler:
        // that would skip the batch's credit replenish and permanently burn a
        // send credit per throw (eight throws = a stalled live feed). Treat
        // the line as unclassified; surface the first error once.
        _readerError ??= e;
      }
    }
    // CapturedLine is immutable; the copy stamps seq (and the tag, if any).
    final line = CapturedLine(
        bytes: l.bytes, stream: l.stream, at: l.at, source: source, seq: _seq++);
    _history.add(line);
    if (_history.length > _historyLines) {
      final evicted = _history.removeFirst();
      _evictedLines++;
      _evictedBytes += evicted.bytes.length;
    }
    if (!_combined.isClosed) _combined.add(line);
    final c = line.stream == StdStream.out ? _out : _err;
    if (!c.isClosed) c.add(line);
  }

  /// Spawn a child, tagging its stdout/stderr with [source] and merging them
  /// into this capture. Started in `normal` mode (separate pipes) so its lines
  /// can be tagged — an `inheritStdio` child would flow through fd 1/2 already,
  /// untagged. The returned [CapturedProcess] carries the process plus a
  /// [CapturedProcess.drained] future for awaiting full delivery.
  ///
  /// Delivery for tagged children rides the MAIN isolate's event loop (unlike
  /// fd 1/2, which the reader isolate drains even when main stalls) — so a
  /// stalled main isolate backpressures the child instead of this process.
  ///
  /// Throws [StateError] if the capture is already stopped (or its reader
  /// died — see [readerError]): a child started then would have its output
  /// silently discarded.
  Future<CapturedProcess> startProcess(String executable, List<String> arguments,
      {required String source,
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment = true,
      bool runInShell = false}) async {
    _checkLive();
    final proc = await io.Process.start(executable, arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        includeParentEnvironment: includeParentEnvironment,
        runInShell: runInShell);
    try {
      return CapturedProcess._(proc, adopt(proc, source: source));
    } on StateError {
      // The session stopped during the spawn await. Don't leak a child no one
      // can reach — its unlistened pipes would wedge it at ~64 KiB anyway.
      proc.kill();
      rethrow;
    }
  }

  /// Tag an already-started (`normal`-mode) child's output with [source] and
  /// merge it. Only safe if nothing else has listened to [child]'s streams
  /// yet. The returned future completes when the child's output has been
  /// fully delivered into the capture (see [CapturedProcess.drained]).
  ///
  /// Throws [StateError] if the capture is already stopped (or its reader
  /// died — see [readerError]), instead of silently discarding the output.
  Future<void> adopt(io.Process child, {required String source}) {
    _checkLive();
    final out = _pipeChild(child.stdout, StdStream.out, source);
    final err = _pipeChild(child.stderr, StdStream.err, source);
    return Future.wait([out, err]).then((_) {});
  }

  Future<void> _pipeChild(Stream<List<int>> stream, StdStream s, String source) {
    final asm = LineAssembler(
        (bytes) => _emit(CapturedLine(
            bytes: bytes,
            stream: s,
            at: DateTime.now(),
            source: source,
            seq: -1 /* stamped in _emit */)),
        maxLineBytes: _maxLineBytes);
    final done = Completer<void>();
    stream.listen(
      (chunk) => asm.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk)),
      // A stream error can't be routed anywhere useful; delivery simply ends
      // with whatever arrived (onDone still fires and completes the drain).
      onError: (Object _) {},
      onDone: () {
        asm.flush();
        done.complete();
      },
    );
    return done.future;
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
  /// [terminal]/[terminalStderr] all stay live; writes during the pause go
  /// straight to the terminal and are NOT captured.
  ///
  /// This is the terminal-handoff primitive for TUIs: suspend capture, spawn
  /// `$EDITOR`/a pager with `ProcessStartMode.inheritStdio` (the child
  /// inherits the *real* descriptors), then [resume] when it exits. Dart's
  /// buffered stdout/stderr are flushed into the pipe first, so bytes written
  /// before the pause stay part of the capture.
  ///
  /// No-op if already paused. Throws [StateError] after [stop], or if the
  /// reader died mid-session (see [readerError]).
  ///
  /// **Caveat — `mirrorToOriginal` sessions:** the mirror keeps `O_NONBLOCK`
  /// set on the saved descriptions for the session's lifetime (its never-block
  /// contract; only [stop] restores the original flags). During a pause those
  /// descriptions ARE fd 1/2 again, so on a slow terminal a handed-off child's
  /// (or your own) writes can see `EAGAIN` short-writes. Prefer not combining
  /// [pause] handoffs with `mirrorToOriginal: true`.
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
  /// No-op if not paused. Throws [StateError] after [stop], or if the reader
  /// died mid-session (re-redirecting would point fd 1/2 at pipes nothing
  /// drains — see [readerError]).
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
    if (_readerDied) {
      // The session is degraded: fd 1/2 were already restored (nothing drains
      // the pipes anymore), so re-redirecting (resume) or merging new work
      // (startProcess/adopt) would misbehave. stop() is the only useful call.
      throw StateError('stdio: reader died mid-session ($_readerError) — '
          'the capture is degraded; call stop().');
    }
  }

  static void _dup2Checked(int from, int to, String op) {
    if (dup2(from, to) < 0) {
      throw StdioException(
          'stdio: $op dup2($from, $to) failed: errno=$errno');
    }
  }

  /// Restore fd 1/2 and tear down, returning the retained transcript — the
  /// last `historyLines` lines (see [Captured.droppedLines] for what is
  /// missing), with `void` as the [Captured.value]. Idempotent and
  /// concurrent-safe: every call awaits the same teardown and gets an
  /// equivalent snapshot. After this returns, [terminal]/[terminalStderr] are
  /// invalid (their fd is closed). Teardown order: restore fd 1/2, EOF the
  /// reader, drain to completion (bounded), then close — nothing in flight is
  /// lost and no writer sees EPIPE. Safe to call while [pause]d (the restore
  /// is idempotent).
  Future<Captured<void>> stop() async {
    final lines = await _finish();
    return Captured<void>(null, lines,
        droppedLines: droppedLines, droppedBytes: droppedBytes);
  }

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
    var timedOut = false;
    await _readerDone.future.timeout(const Duration(seconds: 2), onTimeout: () {
      timedOut = true;
    });

    final snapshot = List<CapturedLine>.of(_history);
    _closed = true;
    _paused = false;

    // (4) restore the original file-status flags on the saved descriptions
    // BEFORE closing them: the mirror-to-original path set O_NONBLOCK there,
    // and the restored fd 1/2 share those descriptions — without this, the
    // app's post-stop writes can EAGAIN, and a tty target leaves the parent
    // shell's stdout non-blocking after this process exits. Unconditional so
    // it holds on every exit path, including the drain-timeout path below.
    if (_savedFdFlags >= 0) fdSetFlags(_savedFd, _savedFdFlags);
    if (_savedErrFdFlags >= 0) fdSetFlags(_savedErrFd, _savedErrFdFlags);

    // (5) close fds + ports + streams. Two paths:
    //
    // Normal (the reader drained and reported done, or died — either way it
    // will never touch its fds again): close everything.
    //
    // Timeout (the reader is wedged but possibly ALIVE, blocked in a syscall
    // where kill() can't interrupt it until it returns to Dart): deliberately
    // LEAK the fds it may still be blocked in read()/poll() on — and, in
    // mirror mode, writing to. Closing them would free the numbers for reuse,
    // and the stuck reader would then steal bytes from (or write into) an
    // unrelated fd. The leak is bounded: a few fds, once, on an
    // already-broken session. kill() is issued ONLY here — on the normal path
    // it could race a healthy reader's `finally` (which frees its native
    // buffers and closes the mirror-file fd).
    if (timedOut) {
      _isolate.kill(priority: Isolate.immediate);
    } else {
      closeFd(_outReadFd);
      closeFd(_errReadFd);
      closeFd(_controlReadFd);
    }
    closeFd(_controlWriteFd);
    if (!(timedOut && _mirrorToOriginal)) {
      closeFd(_savedFd);
      closeFd(_savedErrFd);
    }
    _fromReader.close();
    await _combined.close();
    await _out.close();
    await _err.close();
    _busy = false;
    return snapshot;
  }

  /// Scoped capture: the window is exactly the execution of [body], and
  /// [Captured.value] is what [body] returned.
  ///
  /// Desugars to `start()` → `await body()` → `stop()` in a finally — so fd
  /// 1/2 are restored even when [body] throws. If [body] throws, the
  /// exception propagates and the transcript is LOST with it; when you need
  /// post-mortem output around a failure, use [start]/[stop] and keep the
  /// session handle. The result holds the retained transcript — the last
  /// [historyLines] lines, with anything beyond that counted in
  /// [Captured.droppedLines] (the teardown does drain the pipes to EOF
  /// first, so nothing in flight at return time is truncated).
  ///
  /// The options forward to [start] and mean the same things there:
  /// [historyLines] (>= 1), [maxLineBytes] (>= 1024) — out-of-range values
  /// throw [ArgumentError] — plus [mirrorToFile] and [classify].
  ///
  /// Call from the main isolate only, like [start]. Throws [StateError] if a
  /// capture/redirect is already active (fd redirection is process-global,
  /// one at a time).
  ///
  /// The `Process.run` to [start]'s `Process.start`: use this when the
  /// capture doesn't outlive one call — tests, wrapping a noisy init.
  static Future<Captured<T>> capture<T>(FutureOr<T> Function() body,
      {int historyLines = 4096,
      int maxLineBytes = 64 * 1024,
      io.File? mirrorToFile,
      String? Function(CapturedLine line)? classify}) async {
    final cap = await Stdio.start(
        historyLines: historyLines,
        maxLineBytes: maxLineBytes,
        mirrorToFile: mirrorToFile,
        classify: classify);
    final T value;
    List<CapturedLine> lines;
    try {
      value = await body();
    } finally {
      lines = await cap._finish();
    }
    return Captured<T>(value, lines,
        droppedLines: cap.droppedLines, droppedBytes: cap.droppedBytes);
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
  /// duplicate). Note it moves BOTH descriptors — there is no
  /// stdout-only/stderr-only mode; after this call nothing the process
  /// prints reaches the terminal until [StdioRedirect.stop].
  ///
  /// Call from the main isolate only (see [start]). Throws [StateError] if a
  /// capture/redirect is already active — fd redirection is process-global,
  /// one at a time.
  static Future<StdioRedirect> redirectToFile(io.File file,
      {bool append = true}) async {
    if (_busy) {
      throw StateError('stdio: a capture/redirect is already active.');
    }
    _busy = true;
    final opened = <int>[];
    try {
      final saved1 = dup(1);
      if (saved1 < 0) throw StdioException('dup(1) failed: errno=$errno');
      opened.add(saved1);
      setCloexec(saved1);
      final saved2 = dup(2);
      if (saved2 < 0) throw StdioException('dup(2) failed: errno=$errno');
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
