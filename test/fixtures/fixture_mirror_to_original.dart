// mirrorToOriginal end-to-end: raw captured chunks are mirrored back to
// wherever fd 1/2 originally pointed (this fixture's real stdout/stderr — the
// harness's pipes), byte-transparent and split-intact, while the capture
// still assembles them into lines. Also pins CapturedLine.seq: monotonic,
// consecutive, assigned across every delivered line.
//
// The harness asserts the mirrored bytes on ITS side (the subprocess's real
// stdout/stderr); this fixture asserts the capture side + seq and reports on
// stderr AFTER stop().

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:stdio/stdio.dart';

final _write = DynamicLibrary.process().lookupFunction<
    IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
    int Function(int, Pointer<Uint8>, int)>('write');

void nativeWrite(int fd, String s) {
  final bytes = utf8.encode(s);
  final buf = malloc<Uint8>(bytes.length);
  buf.asTypedList(bytes.length).setAll(0, bytes);
  var off = 0;
  while (off < bytes.length) {
    final w = _write(fd, buf + off, bytes.length - off);
    if (w <= 0) break;
    off += w;
  }
  malloc.free(buf);
}

Future<void> main() async {
  final s = await Stdio.start(mirrorToOriginal: true);
  final seen = <CapturedLine>[];
  s.output.listen(seen.add);

  print('mirror-dart-line');
  // A PARTIAL write with no newline: the raw mirror must pass it through
  // immediately and unmodified, even though line assembly holds it until the
  // stop() flush.
  nativeWrite(1, 'mirror-native-partial');
  nativeWrite(2, 'mirror-err-line\n');
  await Future<void>.delayed(const Duration(milliseconds: 200));

  final cap = await s.stop();

  var failures = 0;
  void check(bool ok, String label) {
    stderr.writeln('${ok ? "  ok" : "  FAIL"}  $label');
    if (!ok) failures++;
  }

  check(cap.lines.any((l) => l.text == 'mirror-dart-line'),
      'capture still assembles the mirrored stdout line');
  check(
      cap.lines.any(
          (l) => l.text == 'mirror-native-partial' && l.stream == StdStream.out),
      'the newline-less partial is flushed into the capture at stop');
  check(
      cap.lines.any(
          (l) => l.text == 'mirror-err-line' && l.stream == StdStream.err),
      'capture keeps the fd 2 line on the err stream');
  check(s.mirrorDroppedBytes == 0,
      'nothing dropped on a drained mirror target '
      '(${s.mirrorDroppedBytes} bytes)');

  // seq: consecutive from 0 across every delivered line, and history is a
  // suffix of the delivered sequence.
  var seqOk = seen.isNotEmpty;
  for (var i = 0; i < seen.length; i++) {
    if (seen[i].seq != i) seqOk = false;
  }
  check(seqOk, 'stream seq is 0..n-1 consecutive (${seen.length} lines)');
  final histSeqs = cap.lines.map((l) => l.seq).toList();
  var suffixOk = histSeqs.isNotEmpty;
  for (var i = 1; i < histSeqs.length; i++) {
    if (histSeqs[i] != histSeqs[i - 1] + 1) suffixOk = false;
  }
  check(suffixOk && histSeqs.last == seen.length - 1,
      'history seqs are the consecutive tail of the delivered sequence');

  stderr.writeln(failures == 0 ? 'MIRROR-E2E-OK' : 'MIRROR-E2E-FAILED');
  exit(failures == 0 ? 0 : 1);
}
