import 'dart:typed_data';

import 'package:stdio/stdio.dart';
import 'package:test/test.dart';

CapturedLine line(List<int> bytes) => CapturedLine(
    bytes: Uint8List.fromList(bytes),
    stream: StdStream.out,
    at: DateTime(2026),
    seq: 0);

void main() {
  test('text strips exactly ONE trailing CR; bytes keep it (D11)', () {
    final crlf = line([0x68, 0x69, 0x0D]); // "hi\r" (the \n was stripped)
    expect(crlf.text, 'hi', reason: 'CRLF line reads clean');
    expect(crlf.bytes, [0x68, 0x69, 0x0D],
        reason: 'bytes stay byte-exact — fidelity is their contract');

    final doubleCr = line([0x68, 0x0D, 0x0D]); // "h\r\r"
    expect(doubleCr.text, 'h\r', reason: 'only ONE trailing CR is stripped');

    final interior = line([0x61, 0x0D, 0x62]); // "a\rb" — progress-bar style
    expect(interior.text, 'a\rb', reason: 'interior CRs pass through');

    final bare = line([0x0D]);
    expect(bare.text, '', reason: 'a lone CR strips to empty');
    expect(bare.bytes, [0x0D]);

    expect(line([]).text, '', reason: 'empty line is fine');
  });

  test('text decodes UTF-8 with replacement, computed once', () {
    final l = line([0xE2, 0x98, 0x83]); // ☃
    expect(l.text, '☃');
    final bad = line([0xFF, 0xFE]);
    expect(bad.text.isNotEmpty, isTrue, reason: 'malformed input never throws');
  });
}
