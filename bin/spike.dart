// Task-0 spike. Answers the make-or-break questions before we build:
//
//   1. Can we bind dup/dup2/pipe/read/write/close via FFI on this platform?
//   2. Does Dart's OWN output (`print`, `stdout.write`) follow fd 1 after a
//      dup2 — i.e. does Dart write to the descriptor by NUMBER (so the redirect
//      catches it), or does it cache a private handle at startup?
//   3. Does a raw FFI write(1, …) land in the pipe (native path — the part that
//      MUST work)?
//   4. Does reading the pipe drain it without deadlock?
//
// All diagnostics go to STDERR (fd 2), which we deliberately leave un-redirected,
// so this script's own report is always visible on the real terminal.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final DynamicLibrary _libc = DynamicLibrary.process();

final int Function(int) _dup =
    _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('dup');
final int Function(int, int) _dup2 = _libc
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('dup2');
final int Function(Pointer<Int32>) _pipe = _libc
    .lookupFunction<Int32 Function(Pointer<Int32>), int Function(Pointer<Int32>)>(
        'pipe');
final int Function(int, Pointer<Uint8>, int) _read = _libc.lookupFunction<
    IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
    int Function(int, Pointer<Uint8>, int)>('read');
final int Function(int, Pointer<Uint8>, int) _write = _libc.lookupFunction<
    IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
    int Function(int, Pointer<Uint8>, int)>('write');
final int Function(int) _close =
    _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');

void log(String m) => stderr.writeln('[spike] $m');

Future<void> main() async {
  log('dup/dup2/pipe/read/write/close bound OK');

  // 1. Save the real stdout.
  final savedFd = _dup(1);
  log('savedFd = dup(1) => $savedFd');
  if (savedFd < 0) {
    log('FAIL: dup(1) failed');
    exit(1);
  }

  // 2. Create a pipe.
  final fdPair = malloc<Int32>(2);
  final pr = _pipe(fdPair);
  final readFd = fdPair[0];
  final writeFd = fdPair[1];
  malloc.free(fdPair);
  log('pipe() => rc=$pr read=$readFd write=$writeFd');
  if (pr != 0) {
    log('FAIL: pipe() failed');
    exit(1);
  }

  // 3. Redirect fd 1 -> pipe write end.
  final d = _dup2(writeFd, 1);
  log('dup2(writeFd=$writeFd, 1) => $d');

  // 4. Emit via all three paths while fd 1 is the pipe.
  print('DART-PRINT');
  stdout.write('DART-STDOUT\n');
  await stdout.flush(); // force Dart's buffer out to fd 1 (now the pipe)

  const ffiMsg = 'FFI-WRITE-1\n';
  final bytes = utf8.encode(ffiMsg);
  final buf = malloc<Uint8>(bytes.length);
  buf.asTypedList(bytes.length).setAll(0, bytes);
  final w = _write(1, buf, bytes.length);
  malloc.free(buf);
  log('write(1, "FFI-WRITE-1") => $w bytes');

  // 5. Restore fd 1 -> real terminal, then close the write ends so read() sees EOF.
  _dup2(savedFd, 1);
  _close(writeFd);
  _close(savedFd);
  log('restored fd 1; closed writeFd + savedFd');

  // 6. Drain the pipe.
  final out = <int>[];
  final rbuf = malloc<Uint8>(4096);
  while (true) {
    final n = _read(readFd, rbuf, 4096);
    if (n <= 0) break; // 0 = EOF, <0 = error
    out.addAll(rbuf.asTypedList(n));
  }
  malloc.free(rbuf);
  _close(readFd);

  final captured = utf8.decode(out, allowMalformed: true);
  log('--- captured from the pipe (${out.length} bytes) ---');
  for (final line in const LineSplitter().convert(captured)) {
    log('  | $line');
  }

  // 7. Verdict.
  final gotFfi = captured.contains('FFI-WRITE-1');
  final gotPrint = captured.contains('DART-PRINT');
  final gotStdout = captured.contains('DART-STDOUT');
  log('=== VERDICT ===');
  log('native write(1) captured : $gotFfi   <- MUST be true (the core)');
  log('Dart print captured      : $gotPrint');
  log('Dart stdout.write capt.  : $gotStdout');
  if (gotFfi && gotPrint && gotStdout) {
    log('>>> Dart writes fd 1 by number — dup2 catches EVERYTHING. Fleury can delete its zone.');
  } else if (gotFfi) {
    log('>>> Native captured, but Dart\'s own output escaped — keep a Dart-level shim for print().');
  } else {
    log('>>> UNEXPECTED: native write not captured. Investigate before proceeding.');
  }
}
