import 'dart:typed_data';

/// Splits a byte stream into whole lines on the `0x0A` (`\n`) byte, carrying a
/// partial line across chunk boundaries. `\n` never appears inside a multi-byte
/// UTF-8 sequence, so splitting on the byte is codepoint-safe even when a write
/// straddles a `read()` boundary — which is why bytes, not decoded text, are the
/// unit here.
///
/// Callers MUST pass chunks that don't alias reused memory (copy out of a native
/// read buffer first); the assembler retains bytes until a line completes.
class LineAssembler {
  LineAssembler(this._onLine);

  /// Invoked with each completed line's bytes (newline stripped, owned by the
  /// callee).
  final void Function(Uint8List lineBytes) _onLine;

  final BytesBuilder _partial = BytesBuilder();

  /// Feed a chunk; emits zero or more whole lines.
  void add(Uint8List chunk) {
    var start = 0;
    for (var i = 0; i < chunk.length; i++) {
      if (chunk[i] == 0x0A) {
        _partial.add(Uint8List.sublistView(chunk, start, i));
        _onLine(_partial.takeBytes());
        start = i + 1;
      }
    }
    if (start < chunk.length) {
      _partial.add(Uint8List.sublistView(chunk, start));
    }
  }

  /// Emit any trailing bytes with no final newline (call at EOF).
  void flush() {
    if (_partial.isNotEmpty) _onLine(_partial.takeBytes());
  }

  bool get hasPartial => _partial.isNotEmpty;
}
