/// File-descriptor-level capture of stdout/stderr for Dart — including output
/// from native/FFI code and inherited subprocesses that bypass Dart's stream
/// objects. POSIX (Linux + macOS).
///
/// See [StdioCapture] for the three entry points: [StdioCapture.start] (a
/// long-lived controller), [StdioCapture.collect] (scoped), and
/// [StdioCapture.divertToFile] (direct redirect, no draining).
library;

export 'src/captured_line.dart' show CapturedLine, StdStream;
export 'src/stdio_capture_base.dart' show Captured, StdioCapture, StdioRedirect;
export 'src/terminal_sink.dart' show StdoutTerminalSink, TerminalSink;
