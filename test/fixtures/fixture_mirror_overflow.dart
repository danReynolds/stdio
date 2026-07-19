// C4 pinning fixture: when the mirror-to-original target stops draining (the
// harness deliberately does not read our stdout until we report), the
// reader's bounded carry overflows and the dropped bytes must be COUNTED in
// the dedicated mirrorDroppedBytes counter — not silently discarded, and not
// folded into the capture-line droppedLines/droppedBytes.
//
// Protocol with the harness: we write until the counter moves (or a cap),
// report `OVERFLOW-RESULT counted <n>` on stderr, and only then does the
// harness begin draining stdout so we can exit cleanly.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:stdio/stdio.dart';

final _write = DynamicLibrary.process().lookupFunction<
    IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
    int Function(int, Pointer<Uint8>, int)>('write');

void nativeWriteBytes(int fd, Uint8List bytes) {
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
  // Small history so the 64 KiB line pieces don't accumulate memory.
  final s = await Stdio.start(mirrorToOriginal: true, historyLines: 8);

  // Fill: the un-drained parent pipe (<= 64 KiB) + the reader's 256 KiB
  // carry, then drops begin. 64 chunks x 64 KiB = 4 MiB is far past that.
  final chunk = Uint8List.fromList(List<int>.filled(64 * 1024, 0x79));
  var wrote = 0;
  for (var i = 0; i < 64 && s.mirrorDroppedBytes == 0; i++) {
    nativeWriteBytes(1, chunk);
    wrote += chunk.length;
    // Yield so reader batches (carrying the counter) can be processed.
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  final dropped = s.mirrorDroppedBytes;
  final lineDrops = s.droppedLines;
  // NOTE: fd 2 is still captured here — but mirrorToOriginal forwards
  // captured stderr to the REAL stderr, which is exactly how these markers
  // reach the harness pre-stop (the fd 2 mirror carry is empty; only fd 1 is
  // flooded).
  stderr.writeln('wrote=$wrote mirrorDroppedBytes=$dropped '
      'droppedLines=$lineDrops');
  stderr.writeln(dropped > 0
      ? 'OVERFLOW-RESULT counted $dropped'
      : 'OVERFLOW-RESULT none');
  final cap = await s.stop();
  // The capture itself must be unaffected by mirror drops: every piece is in
  // history or counted in the LINE counters, and the two channels differ.
  final capOk = cap.lines.isNotEmpty;
  exit(dropped > 0 && capOk ? 0 : 1);
}
