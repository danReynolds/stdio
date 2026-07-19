import 'dart:convert';
import 'dart:typed_data';

import 'package:stdio/src/line_assembler.dart';
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

  test('caps a newline-less run at maxLineBytes — split, not dropped', () {
    final pieces = <int>[];
    final total = <int>[];
    final a = LineAssembler((b) {
      pieces.add(b.length);
      total.addAll(b);
    }, maxLineBytes: 1024);
    a.add(Uint8List.fromList(List.filled(3000, 0x78))); // 3000 × 'x', no \n
    expect(pieces, [1024, 1024], reason: 'two full pieces, 952 carried');
    expect(a.hasPartial, isTrue);
    a.add(b('tail\n'));
    expect(pieces.last, 952 + 4, reason: 'carry + tail flushed by the newline');
    a.flush();
    expect(total.length, 3000 + 4, reason: 'every byte delivered exactly once');
    expect(pieces.every((p) => p <= 1024), isTrue);
  });

  test('exact-cap run leaves no partial behind', () {
    final pieces = <int>[];
    final a = LineAssembler((b) => pieces.add(b.length), maxLineBytes: 1024);
    a.add(Uint8List.fromList(List.filled(1024, 0x78)));
    expect(pieces, [1024]);
    expect(a.hasPartial, isFalse);
  });

  test('caps a newline-TERMINATED line arriving in one chunk (B2)', () {
    // The newline branch must route through the same cap-splitting as the
    // tail carry: a 40000-byte terminated line with cap=1024 previously
    // bypassed the cap entirely and was emitted as one 40000-byte line.
    final pieces = <int>[];
    var total = 0;
    final a = LineAssembler((b) {
      pieces.add(b.length);
      total += b.length;
    }, maxLineBytes: 1024);
    a.add(Uint8List.fromList([...List.filled(40000, 0x78), 0x0A]));
    expect(pieces.every((p) => p <= 1024), isTrue,
        reason: 'no piece may exceed the cap (got max '
            '${pieces.reduce((m, p) => p > m ? p : m)})');
    expect(total, 40000, reason: 'byte-exact: split, not dropped');
    expect(pieces, [...List.filled(39, 1024), 64],
        reason: '39 full pieces + the 64-byte remainder');
    expect(a.hasPartial, isFalse);
  });

  test('caps a carried partial + terminated segment combo (B2)', () {
    final pieces = <int>[];
    var total = 0;
    final a = LineAssembler((b) {
      pieces.add(b.length);
      total += b.length;
    }, maxLineBytes: 1024);
    a.add(Uint8List.fromList(List.filled(500, 0x61))); // carried, no newline
    expect(a.hasPartial, isTrue);
    a.add(Uint8List.fromList([...List.filled(700, 0x62), 0x0A]));
    expect(total, 1200, reason: 'every byte delivered exactly once');
    expect(pieces, [1024, 176],
        reason: 'combined 1200 > cap: one full piece, then the remainder');
    expect(a.hasPartial, isFalse);
  });

  test('exact-cap terminated line is NOT split (B2)', () {
    final pieces = <int>[];
    final a = LineAssembler((b) => pieces.add(b.length), maxLineBytes: 1024);
    a.add(Uint8List.fromList([...List.filled(1024, 0x78), 0x0A]));
    expect(pieces, [1024],
        reason: 'a line exactly at the cap stays one line — no empty-piece '
            'artifact');
    expect(a.hasPartial, isFalse);
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
