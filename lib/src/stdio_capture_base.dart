import 'dart:async';
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

  /// Restore fd 1/2 to the terminal. Idempotent.
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

  final int _savedFd;
  final int _outWriteFd;
  final int _errWriteFd;
  final int _outReadFd;
  final int _errReadFd;
  final int _controlReadFd;
  final int _controlWriteFd;
  final Isolate _isolate;
  final ReceivePort _fromReader;
  final int _backlogLines;

  /// The real terminal, for rendering (the saved dup of fd 1).
  final TerminalSink terminal;

  /// The same terminal as a concrete [io.Stdout], for consumers (a TUI driver)
  /// that require the concrete type rather than a [TerminalSink]/[IOSink].
  late final io.Stdout terminalStdout = StdoutTerminalSink(_savedFd);

  final _out = StreamController<CapturedLine>.broadcast();
  final _err = StreamController<CapturedLine>.broadcast();
  final _combined = StreamController<CapturedLine>.broadcast();
  final _history = <CapturedLine>[];
  final _readerDone = Completer<void>();

  int _droppedLines = 0;
  int _droppedBytes = 0;
  bool _stopped = false;

  /// Optional best-effort source tag for the in-process merged stream.
  String? Function(CapturedLine line)? _classify;

  /// stdout lines only (exact within-stream order). Broadcast — pair with
  /// [history] for output produced before you subscribed.
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

  bool get isActive => !_stopped;

  /// Redirect fd 1/2 into the capture and drain off-isolate. Throws [StateError]
  /// if a capture/redirect is already active (fd redirection is process-global).
  static Future<StdioCapture> start({
    int backlogLines = 4096,
    io.File? mirrorToFile,
    String? Function(CapturedLine line)? classify,
  }) async {
    if (_busy) {
      throw StateError(
          'stdio_capture: a capture/redirect is already active. fd redirection '
          'is process-global — stop the current one first.');
    }
    _busy = true;

    // Roll back any fd we changed if setup fails partway.
    final opened = <int>[];
    void track(int fd) => opened.add(fd);
    try {
      final savedFd = dup(1);
      if (savedFd < 0) throw StdioCaptureException('dup(1) failed');
      track(savedFd);
      setCloexec(savedFd);

      final (outR, outW) = makePipe();
      track(outR);
      track(outW);
      setCloexec(outR);
      setCloexec(outW);
      final (errR, errW) = makePipe();
      track(errR);
      track(errW);
      setCloexec(errR);
      setCloexec(errW);
      final (ctrlR, ctrlW) = makePipe();
      track(ctrlR);
      track(ctrlW);
      setCloexec(ctrlR);
      setCloexec(ctrlW);

      // Redirect. dup2 clears CLOEXEC on the target, so fd 1/2 stay inheritable.
      dup2(outW, 1);
      dup2(errW, 2);

      final fromReader = ReceivePort();
      final isolate = await Isolate.spawn(
        readerMain,
        ReaderConfig(
          outReadFd: outR,
          errReadFd: errR,
          controlReadFd: ctrlR,
          toMain: fromReader.sendPort,
          backlogLines: backlogLines,
          mirrorPath: mirrorToFile?.path,
        ),
        debugName: 'stdio_capture.reader',
      );

      final cap = StdioCapture._(
        savedFd: savedFd,
        outWriteFd: outW,
        errWriteFd: errW,
        outReadFd: outR,
        errReadFd: errR,
        controlReadFd: ctrlR,
        controlWriteFd: ctrlW,
        isolate: isolate,
        fromReader: fromReader,
        terminal: FdTerminalSink(savedFd),
        backlogLines: backlogLines,
      );
      cap._classify = classify;
      fromReader.listen(cap._onReaderMessage);
      return cap;
    } catch (e) {
      // Best-effort rollback: restore fd 1/2 and close what we opened.
      dup2(opened.isNotEmpty ? opened.first : 1, 1);
      dup2(opened.isNotEmpty ? opened.first : 2, 2);
      for (final fd in opened) {
        closeFd(fd);
      }
      _busy = false;
      rethrow;
    }
  }

  void _onReaderMessage(dynamic msg) {
    if (msg is! ReaderBatch) return;
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
    if (l.source == null && _classify != null) l.source = _classify!(l);
    _history.add(l);
    if (_history.length > _backlogLines) _history.removeAt(0);
    if (!_combined.isClosed) _combined.add(l);
    final c = l.stream == StdStream.out ? _out : _err;
    if (!c.isClosed) c.add(l);
  }

  /// Spawn a child, tagging its stdout/stderr with [source] and merging them
  /// into this capture. Started in `normal` mode (separate pipes) so its lines
  /// can be tagged — an `inheritStdio` child would flow through fd 1/2 already,
  /// untagged.
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

  /// Restore fd 1/2 and tear down. Idempotent. See §7.3 for the ordering.
  Future<void> stop() => _finish();

  Future<List<CapturedLine>> _finish() async {
    if (_stopped) return List<CapturedLine>.of(_history);
    _stopped = true;

    // Flush Dart's own buffered stdout/stderr into the pipe BEFORE we restore,
    // or those bytes would surface on the terminal after the swap.
    try {
      await io.stdout.flush();
    } catch (_) {}
    try {
      await io.stderr.flush();
    } catch (_) {}

    // (1) restore fd 1/2 so no new bytes enter the pipes.
    dup2(_savedFd, 1);
    dup2(_savedFd, 2);
    // (2) close the write ends → reader hits EOF; also signal stop for the case
    // where an inherited child still holds a pipe write end.
    closeFd(_outWriteFd);
    closeFd(_errWriteFd);
    _sendControl(ctrlStop);
    // (3) wait for the reader to drain + finish (bounded — a stuck child that
    // never EOFs won't hang us forever).
    await _readerDone.future.timeout(const Duration(seconds: 2), onTimeout: () {});

    final snapshot = List<CapturedLine>.of(_history);

    // (4) close read ends + control + saved; kill the isolate; close streams.
    closeFd(_outReadFd);
    closeFd(_errReadFd);
    closeFd(_controlReadFd);
    closeFd(_controlWriteFd);
    closeFd(_savedFd);
    _isolate.kill(priority: Isolate.immediate);
    _fromReader.close();
    await _combined.close();
    await _out.close();
    await _err.close();
    _busy = false;
    return snapshot;
  }

  /// Scoped capture — runs [body] with fd 1/2 captured and returns everything,
  /// restoring after (even on throw). Built on [start]; process-global (§6.2).
  static Future<Captured> collect(FutureOr<void> Function() body) async {
    final cap = await StdioCapture.start();
    try {
      await body();
    } finally {
      // Let the reader drain the last writes before we tear down.
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final lines = await cap._finish();
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
    try {
      final saved1 = dup(1);
      final saved2 = dup(2);
      setCloexec(saved1);
      setCloexec(saved2);
      final fileFd = openForWrite(file.path, append: append);
      dup2(fileFd, 1);
      dup2(fileFd, 2);
      closeFd(fileFd); // fd 1/2 hold the file now; the extra fd isn't needed
      return StdioRedirect._(saved1, saved2);
    } catch (e) {
      _busy = false;
      rethrow;
    }
  }
}
