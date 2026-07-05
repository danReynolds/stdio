/// File-descriptor-level capture of stdout/stderr for Dart — including output
/// from native/FFI code and inherited subprocesses that bypass Dart's stream
/// objects. POSIX (Linux + macOS).
///
/// See [StdioCapture] for the three entry points: [StdioCapture.start] (a
/// long-lived session handle), [StdioCapture.capture] (scoped, returns the
/// transcript), and [StdioCapture.redirectToFile] (reroute fd 1/2 to a file,
/// no capture).
library;

export 'src/captured_line.dart' show CapturedLine, StdStream;
export 'src/stdio_capture_base.dart' show Captured, StdioCapture, StdioRedirect;
export 'src/terminal_sink.dart'
    show FdTerminalSink, StdoutTerminalSink, TerminalSink;
