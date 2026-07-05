import 'dart:typed_data';

/// Splits a byte stream into whole lines on the `0x0A` (`\n`) byte, carrying a
/// partial line across chunk boundaries. `\n` never appears inside a multi-byte
/// UTF-8 sequence, so splitting on the byte is codepoint-safe even when a write
/// straddles a `read()` boundary — which is why bytes, not decoded text, are the
/// unit here.
///
/// Contract: [add] only reads the chunk DURING the call and retains no
/// reference to it afterwards — every range is copied into the internal
/// builder as it's scanned (the builder is copy-on-add), and emitted lines are
/// fresh allocations. That's what makes it safe for the reader to pass a view
/// straight over its reused native read buffer. If you change the buffering
/// here, keep the no-retention property or fix those callers.
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
