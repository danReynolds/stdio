import 'dart:async';
import 'dart:convert';
import 'dart:io' show IOSink, Stdout, StdoutException;

import 'posix.dart';

/// A handle to the real terminal — the saved `dup` of fd 1, taken before the
/// redirect. Render through this to reach the screen while everything else is
/// captured. It's an [IOSink] (so it drops into APIs that expect one) plus the
/// terminal-specific accessors a TUI driver needs.
abstract interface class TerminalSink implements IOSink {
  /// Whether the saved fd is a real terminal (`isatty`).
  bool get hasTerminal;

  /// Terminal width in columns via `ioctl(TIOCGWINSZ)`, or null.
  int? get columns;

  /// Terminal height in rows, or null.
  int? get rows;

  /// Whether ANSI escapes are supported (true when it's a terminal).
  bool get supportsAnsiEscapes;

  /// The saved fd. Advanced: do not `close()` it or write to it concurrently
  /// with this sink.
  int get fd;
}

/// [TerminalSink] backed by direct FFI `write()`s to a fd. Writes are synchronous
/// and loop over partial writes / EINTR (see [fdWriteAll] in posix.dart), so a
/// frame can't be truncated.
final class FdTerminalSink implements TerminalSink {
  FdTerminalSink(int fd, {this.encoding = utf8}) : _fd = fd;

  final int _fd;

  @override
  Encoding encoding;

  @override
  int get fd => _fd;

  @override
  bool get hasTerminal => isatty(_fd) == 1;

  @override
  int? get columns => terminalSize(_fd)?.$1;

  @override
  int? get rows => terminalSize(_fd)?.$2;

  @override
  bool get supportsAnsiEscapes => hasTerminal;

  @override
  void add(List<int> data) => fdWriteAll(_fd, data);

  @override
  void write(Object? object) {
    final s = '$object';
    if (s.isNotEmpty) add(encoding.encode(s));
  }

  @override
  void writeln([Object? object = '']) => write('$object\n');

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    final it = objects.iterator;
    if (!it.moveNext()) return;
    final sb = StringBuffer('${it.current}');
    while (it.moveNext()) {
      sb
        ..write(separator)
        ..write(it.current);
    }
    write(sb.toString());
  }

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    // A terminal sink has nowhere to route an error; ignore (matches Stdout's
    // best-effort nature). The renderer surfaces its own errors.
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> flush() async {
    // Writes are unbuffered at this layer (each [add] is a completed write()),
    // so there's nothing to flush.
  }

  @override
  Future<void> close() async {
    // The capture controller owns the fd's lifecycle (it restores + closes on
    // stop()); closing here would break rendering mid-session.
  }

  @override
  Future<void> get done => Future<void>.value();
}

/// A [Stdout]-compatible adapter over the saved terminal fd, for consumers (a
/// TUI driver, say) that expect a concrete [Stdout] rather than an [IOSink].
/// Reuses [FdTerminalSink]'s write path.
final class StdoutTerminalSink extends FdTerminalSink implements Stdout {
  StdoutTerminalSink(super.fd, {super.encoding});

  @override
  int get terminalColumns =>
      columns ?? (throw StdoutException('stdio_capture: not a terminal'));

  @override
  int get terminalLines =>
      rows ?? (throw StdoutException('stdio_capture: not a terminal'));

  @override
  IOSink get nonBlocking => this; // writes are already unbuffered

  @override
  String lineTerminator = '\n';
}
