import 'dart:async';
import 'dart:convert';
import 'dart:io' show IOSink, Stdout, StdoutException;

import 'posix.dart';

/// A handle to the real terminal — a saved `dup` of fd 1/2, taken before the
/// redirect. Render through this to reach the screen while everything else is
/// captured. It's an [IOSink] (so it drops into APIs that expect one) plus the
/// terminal-specific accessors a TUI driver needs.
///
/// Backed by direct FFI `write()`s to the fd. Writes are synchronous and loop
/// over partial writes / EINTR (see [fdWriteAll] in posix.dart), so a frame
/// can't be truncated.
final class FdTerminalSink implements IOSink {
  FdTerminalSink(int fd, {this.encoding = utf8}) : _fd = fd;

  final int _fd;

  @override
  Encoding encoding;

  /// The saved fd. Advanced: do not `close()` it or write to it concurrently
  /// with this sink.
  int get fd => _fd;

  /// Whether the saved fd is a real terminal (`isatty`).
  bool get hasTerminal => isatty(_fd) == 1;

  /// Terminal width in columns via `ioctl(TIOCGWINSZ)`, or null when [fd] is
  /// not a terminal. ([StdoutTerminalSink.terminalColumns] is the
  /// [Stdout]-contract view of the same value: it throws instead of
  /// returning null.)
  int? get columns => terminalSize(_fd)?.$1;

  /// Terminal height in rows, or null when [fd] is not a terminal.
  /// ([StdoutTerminalSink.terminalLines] is the throwing [Stdout]-contract
  /// view.)
  int? get rows => terminalSize(_fd)?.$2;

  /// Whether ANSI escapes are supported (true when it's a terminal).
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

  /// A no-op that completes immediately: writes at this layer are unbuffered
  /// — every [add]/[write] is a completed `write()` syscall by the time it
  /// returns — so there is never anything to flush.
  @override
  Future<void> flush() async {}

  /// A no-op: the capture session owns the saved fd's lifecycle (it restores
  /// and closes it on `stop()`), so closing the sink must not close the fd —
  /// that would break rendering mid-session.
  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Future<void>.value();
}

/// A [Stdout]-compatible adapter over the saved terminal fd, for consumers (a
/// TUI driver, say) that expect a concrete [Stdout] rather than an [IOSink].
/// Reuses [FdTerminalSink]'s write path, and carries both vocabularies for
/// the terminal size: the inherited nullable-safe [columns]/[rows] and the
/// [Stdout]-contract [terminalColumns]/[terminalLines] (which throw when
/// there is no terminal) — same data, two failure contracts.
final class StdoutTerminalSink extends FdTerminalSink implements Stdout {
  StdoutTerminalSink(super.fd, {super.encoding});

  @override
  int get terminalColumns =>
      columns ?? (throw StdoutException('stdio: not a terminal'));

  @override
  int get terminalLines =>
      rows ?? (throw StdoutException('stdio: not a terminal'));

  @override
  IOSink get nonBlocking => this; // writes are already unbuffered

  /// The terminator [writeln] appends — `'\n'` unless you set it.
  ///
  /// Narrower than `dart:io`'s [Stdout.lineTerminator]: it applies ONLY to
  /// the terminator [writeln] itself appends. `'\n'` characters inside
  /// written payloads pass through untranslated — this sink is
  /// byte-transparent (a rendered frame must reach the terminal exactly as
  /// produced).
  @override
  String lineTerminator = '\n';

  @override
  void writeln([Object? object = '']) => write('$object$lineTerminator');
}
