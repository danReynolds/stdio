// C3 pinning fixture: when the reader isolate dies mid-session, fd 1/2 must be
// restored to the saved originals IMMEDIATELY — otherwise they stay pointed at
// pipes nobody drains, and the app's next ~64 KiB of prints wedges the main
// isolate in a blocking write().
//
// A watchdog ISOLATE (timers on the main isolate can't fire while it's wedged
// in a blocking FFI write) hard-exits with code 3 if the post-death writes
// don't complete in time — that is the pre-fix failure mode.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:stdio/src/stdio_base.dart';

final _write = DynamicLibrary.process().lookupFunction<
    IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
    int Function(int, Pointer<Uint8>, int)>('write');

void nativeWriteBytes(int fd, List<int> bytes) {
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

void _watchdog(Object? _) {
  sleep(const Duration(seconds: 15));
  stderr.writeln('WATCHDOG: post-death writes wedged the main isolate');
  exit(3);
}

Future<void> main() async {
  await Isolate.spawn(_watchdog, null);

  final s = await Stdio.start();
  final streamsDone = Completer<void>();
  s.output.listen((_) {}, onDone: streamsDone.complete);

  print('pre-death-line');
  await Future<void>.delayed(const Duration(milliseconds: 120));

  debugKillReaderForTest(s);

  // The death notice arrives on the reader port; streams close and
  // readerError is set.
  await streamsDone.future.timeout(const Duration(seconds: 5));
  if (s.readerError == null) {
    stderr.writeln('FAIL: readerError not set after reader death');
    exit(1);
  }

  // The pin: far more than a pipe's capacity, written from the main isolate.
  // Pre-fix this blocks forever (fd 1 still points at the undrained pipe);
  // post-fix it flows to the restored real stdout — this harness's pipe.
  final blob = List<int>.filled(64 * 1024, 0x7A /* 'z' */);
  for (var i = 0; i < 4; i++) {
    nativeWriteBytes(1, blob); // 256 KiB total
  }
  print('POST-DEATH-MARKER');
  await stdout.flush();

  // stop() must still work (idempotent restore + teardown).
  final cap = await s.stop();
  final sawPreDeath = cap.lines.any((l) => l.text == 'pre-death-line');
  if (!sawPreDeath) {
    stderr.writeln('FAIL: pre-death line missing from the transcript');
    exit(1);
  }
  stderr.writeln('READER-DEATH-OK');
  exit(0);
}
