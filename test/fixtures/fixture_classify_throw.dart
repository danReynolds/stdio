// C-nit pinning fixture: a `classify` callback that throws must not poison
// delivery. Pre-fix, the throw escaped into the reader-port handler BEFORE
// the batch's credit replenish — each throwing batch permanently burned one
// of the reader's 8 send credits, so the live feed stalled after ~8 batches
// (and the port handler crashed with an unhandled error). Post-fix: the line
// is treated as unclassified, delivery continues, and the first error is
// surfaced once on readerError.

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
  const n = 20; // spaced out ⇒ ~20 separate batches, past the 8 credits
  final s = await Stdio.start(
      classify: (l) => throw StateError('classify-boom: ${l.text}'));
  var streamed = 0;
  s.output.listen((_) => streamed++);

  for (var i = 0; i < n; i++) {
    nativeWrite(1, 'cl-$i\n');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  await Future<void>.delayed(const Duration(milliseconds: 200));

  // Evaluate the live-session facts BEFORE stop(), but report only after —
  // writing to stderr now would be captured (fd 2 is still redirected).
  final liveStreamed = streamed;
  final liveReaderError = s.readerError;
  final liveActive = s.isActive;

  final cap = await s.stop();

  var failures = 0;
  void check(bool ok, String label) {
    stderr.writeln('${ok ? "  ok" : "  FAIL"}  $label');
    if (!ok) failures++;
  }

  check(liveStreamed == n,
      'all $n lines delivered LIVE despite the throwing classifier '
      '(got $liveStreamed — a shortfall means burned credits)');
  check(liveReaderError != null,
      'first classify error surfaced on readerError');
  check(liveActive, 'session still active (a classify throw is not a death)');
  check(cap.lines.length == n && cap.lines.every((l) => l.source == null),
      'transcript complete, every line unclassified '
      '(${cap.lines.length} lines)');

  stderr.writeln(failures == 0 ? 'CLASSIFY-THROW-OK' : 'CLASSIFY-THROW-FAILED');
  exit(failures == 0 ? 0 : 1);
}
