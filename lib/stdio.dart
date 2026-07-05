/// File-descriptor-level capture and redirection of **stdout/stderr** —
/// including output from native/FFI code and child processes that bypasses
/// Dart's stream objects entirely. POSIX (Linux + macOS).
///
/// Dart-level mechanisms (zones, `IOOverrides`, swapping `stdout`) can't see
/// bytes that native code writes straight to the file descriptor. This
/// package moves the descriptors themselves (`dup2`), so it catches *every*
/// writer in the process — and hands you a live handle to the real terminal
/// so a TUI can keep rendering while everything else is captured.
///
/// Three entry points on [StdioCapture], shaped like `Process.start`/`run`:
///
/// - [StdioCapture.start] — a live session: [StdioCapture.stdout] /
///   [StdioCapture.stderr] / [StdioCapture.output] line streams,
///   [StdioCapture.history], the [StdioCapture.terminal] render handle,
///   tagged children, [StdioCapture.stop].
/// - [StdioCapture.capture] — scoped: capture exactly one body, get a
///   [Captured] transcript back, restore even on throw.
/// - [StdioCapture.redirectToFile] — reroute fd 1/2 to a file with no capture
///   at all (exact merged order, zero overhead).
///
/// stdin (fd 0) is deliberately untouched: your app — a TUI reading keys, a
/// REPL — keeps its input exactly as it was.
library;

export 'src/captured_line.dart' show CapturedLine, StdStream;
export 'src/stdio_base.dart' show Captured, StdioCapture, StdioRedirect;
export 'src/terminal_sink.dart'
    show FdTerminalSink, StdoutTerminalSink, TerminalSink;
