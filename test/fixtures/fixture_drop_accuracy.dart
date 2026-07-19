// D1 pinning fixture: droppedLines/droppedBytes are numerically EXACT.
//
// The invariant that makes this deterministic regardless of reader/batch
// timing: every one of the K written lines either reaches the session (and
// ends up in history or is evicted from it — evictions counted) or is dropped
// in the reader's ring (counted). History ends holding exactly H lines, so
//
//   droppedLines == K - H   and   droppedBytes == (K - H) * lineBytes
//
// no matter how the drops split between the two sites. The synchronous write
// storm (no awaits) freezes credit replenishment, forcing genuine
// reader-side ring drops so BOTH sites contribute.

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
  const h = 64;
  const k = 20000;
  final payload = 'x' * 63; // 63 stored bytes per line (the \n is stripped)

  final s = await Stdio.start(historyLines: h);
  var streamed = 0;
  var seqConsecutive = true;
  var expectSeq = 0;
  s.output.listen((l) {
    if (l.seq != expectSeq++) seqConsecutive = false;
    streamed++;
  });

  final line = '$payload\n';
  for (var i = 0; i < k; i++) {
    nativeWrite(1, line); // no awaits: main is busy, credits frozen
  }
  await Future<void>.delayed(const Duration(milliseconds: 400));
  final cap = await s.stop();

  var failures = 0;
  void check(bool ok, String label) {
    stderr.writeln('${ok ? "  ok" : "  FAIL"}  $label');
    if (!ok) failures++;
  }

  check(cap.lines.length == h, 'history holds exactly H=$h lines');
  check(cap.droppedLines == k - h,
      'droppedLines exact: ${cap.droppedLines} == $k - $h');
  check(cap.droppedBytes == (k - h) * payload.length,
      'droppedBytes exact: ${cap.droppedBytes} == '
      '${(k - h) * payload.length}');
  check(s.droppedLines == cap.droppedLines &&
      s.droppedBytes == cap.droppedBytes,
      'session counters match the Captured snapshot');
  check(streamed < k,
      'reader-side drops actually occurred ($streamed of $k streamed) — '
      'both drop sites contributed');
  check(streamed >= h, 'at least the final ring reached the session');
  check(seqConsecutive && streamed > 0,
      'delivered seq values are consecutive from 0 under drops');
  check(s.mirrorDroppedBytes == 0,
      'mirror counter untouched (separate channel)');

  stderr.writeln(failures == 0 ? 'DROP-ACCURACY-OK' : 'DROP-ACCURACY-FAILED');
  exit(failures == 0 ? 0 : 1);
}
