import 'dart:convert';
import 'dart:typed_data';

import 'package:stdio_capture/src/line_assembler.dart';
import 'package:test/test.dart';

void main() {
  List<String> run(void Function(LineAssembler a) feed) {
    final out = <String>[];
    final a = LineAssembler((b) => out.add(utf8.decode(b)));
    feed(a);
    return out;
  }

  Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

  test('splits a chunk on newlines, leaving no trailing partial', () {
    final out = run((a) => a.add(b('one\ntwo\nthree\n')));
    expect(out, ['one', 'two', 'three']);
  });

  test('carries a partial line across chunk boundaries', () {
    final out = run((a) {
      a.add(b('hel'));
      a.add(b('lo\nwor'));
      a.add(b('ld\n'));
    });
    expect(out, ['hello', 'world']);
  });

  test('flush() emits a trailing line with no newline', () {
    final out = run((a) {
      a.add(b('no-newline-here'));
      expect(a.hasPartial, isTrue);
      a.flush();
    });
    expect(out, ['no-newline-here']);
  });

  test('reassembles a multi-byte codepoint split across chunks', () {
    // ☃ (U+2603) is E2 98 83 — split it down the middle.
    final bytes = b('snow☃man');
    final cut = 5; // 'snow' (4) + first byte of ☃
    final out = run((a) {
      a.add(Uint8List.sublistView(bytes, 0, cut));
      a.add(Uint8List.sublistView(bytes, cut));
      a.flush();
    });
    expect(out, ['snow☃man']);
  });

  test('blank lines are preserved', () {
    final out = run((a) => a.add(b('a\n\nb\n')));
    expect(out, ['a', '', 'b']);
  });

  test('empty input yields nothing', () {
    expect(run((a) => a.add(b(''))), isEmpty);
    expect(run((a) => a.flush()), isEmpty);
  });

  test('retains no reference to the chunk after add() returns', () {
    // Locks the contract the reader isolate depends on: it hands add() a view
    // over its reused native read buffer, so both the emitted lines AND the
    // carried partial must be copies, unaffected when the buffer is recycled.
    final lines = <String>[];
    final a = LineAssembler((bytes) => lines.add(utf8.decode(bytes)));
    final chunk = b('whole-line\npartial');
    a.add(chunk);
    chunk.fillRange(0, chunk.length, 0x58 /* 'X' — simulate buffer reuse */);
    a.flush();
    expect(lines, ['whole-line', 'partial']);
  });
}
