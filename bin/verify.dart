// End-to-end verification of stdio_capture. Runs standalone (NOT under
// `dart test`, which owns stdout/stderr) and reports via stderr, which we never
// redirect during a check. exit(0) iff everything passes.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:stdio/stdio.dart';

// A stand-in for native/FFI code: write bytes straight to a fd, bypassing Dart.
final _write = DynamicLibrary.process().lookupFunction<
    IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
    int Function(int, Pointer<Uint8>, int)>('write');
void nativeWrite(int fd, String s) => nativeWriteBytes(fd, utf8.encode(s));
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

int _failures = 0;
void check(bool ok, String label) {
  stderr.writeln('${ok ? "  ✓" : "  ✗ FAIL"}  $label');
  if (!ok) _failures++;
}

Future<void> main() async {
  stderr.writeln('== A. capture() captures native + Dart, tagged ==');
  final a = await Stdio.capture(() {
    print('dart-print-out');
    stderr.writeln('dart-stderr-err');
    nativeWrite(1, 'native-out\n');
    nativeWrite(2, 'native-err\n');
  });
  check(a.out.contains('dart-print-out'), 'Dart print → stdout');
  check(a.out.contains('native-out'), 'native write(1) → stdout  [the core]');
  check(a.err.contains('dart-stderr-err'), 'Dart stderr → stderr');
  check(a.err.contains('native-err'), 'native write(2) → stderr  [the core]');
  check(!a.out.contains('native-err') && !a.err.contains('native-out'),
      'streams kept distinct');

  stderr.writeln('== B. start()/stop() controller: streams + history + restore ==');
  final b = await Stdio.start();
  final bOut = <String>[];
  final bAll = <CapturedLine>[];
  b.stdout.listen((l) => bOut.add(l.text));
  b.output.listen(bAll.add);
  print('controller-out-line');
  nativeWrite(2, 'controller-err-line\n');
  await Future<void>.delayed(const Duration(milliseconds: 80));
  final bResult = await b.stop();
  check(b.history.any((l) => l.text.contains('controller-out-line')),
      'history has the stdout line');
  check(b.history.any((l) => l.text.contains('controller-err-line')),
      'history has the stderr line');
  check(
      bAll.any((l) => l.stream == StdStream.out) &&
          bAll.any((l) => l.stream == StdStream.err),
      'output stream carried both, tagged');
  check(
      bResult.out.contains('controller-out-line') &&
          bResult.err.contains('controller-err-line'),
      'stop() returned the transcript (Captured)');
  check(!b.isActive, 'isActive false after stop');

  stderr.writeln('== C. storm: >pipe-capacity while main is busy → no deadlock ==');
  const stormN = 40000;
  final sw = Stopwatch()..start();
  final c = await Stdio.capture(() {
    for (var i = 0; i < stormN; i++) {
      nativeWrite(1, 'storm-line-$i-padding-padding-padding-padding\n');
    }
  });
  sw.stop();
  check(true, 'completed without deadlock in ${sw.elapsedMilliseconds}ms');
  check(c.lines.length < stormN,
      'bounded: kept ${c.lines.length} of $stormN (dropped the rest)');

  stderr.writeln('== D. double-start throws ==');
  final d = await Stdio.start();
  var threw = false;
  try {
    await Stdio.start();
  } on StateError {
    threw = true;
  }
  await d.stop();
  check(threw, 'second start() threw StateError');

  stderr.writeln('== E. redirectToFile writes both streams to a file ==');
  final tmp = File('${Directory.systemTemp.path}/stdio_capture_verify.log');
  if (tmp.existsSync()) tmp.deleteSync();
  final div = await Stdio.redirectToFile(tmp);
  print('file-out-line');
  nativeWrite(2, 'file-err-line\n');
  await stdout.flush();
  await div.stop();
  final contents = tmp.readAsStringSync();
  check(contents.contains('file-out-line') && contents.contains('file-err-line'),
      'file has both lines');
  tmp.deleteSync();

  stderr.writeln('== F. mirrorToFile durable log ==');
  final mirror = File('${Directory.systemTemp.path}/stdio_capture_mirror.log');
  if (mirror.existsSync()) mirror.deleteSync();
  final f = await Stdio.start(mirrorToFile: mirror);
  nativeWrite(1, 'mirror-line-1\n');
  nativeWrite(2, 'mirror-line-2\n');
  await Future<void>.delayed(const Duration(milliseconds: 80));
  await f.stop();
  final mirrorContents = mirror.readAsStringSync();
  check(mirrorContents.contains('mirror-line-1') &&
      mirrorContents.contains('mirror-line-2'), 'mirror file has both lines');
  mirror.deleteSync();

  stderr.writeln('== G. startProcess tags a subprocess ==');
  final g = await Stdio.start();
  final proc = await g.startProcess(
      'sh', ['-c', 'echo child-out; echo child-err >&2'],
      source: 'child');
  await proc.exitCode;
  await Future<void>.delayed(const Duration(milliseconds: 100));
  await g.stop();
  check(
      g.history.any((l) =>
          l.text.contains('child-out') &&
          l.source == 'child' &&
          l.stream == StdStream.out),
      'child stdout tagged source=child');
  check(
      g.history.any((l) =>
          l.text.contains('child-err') &&
          l.source == 'child' &&
          l.stream == StdStream.err),
      'child stderr tagged source=child');

  stderr.writeln('== H. classifier tags the in-process stream ==');
  final h = await Stdio.start(
      classify: (l) => l.text.startsWith('TAG:') ? 'tagged' : null);
  nativeWrite(1, 'TAG:hello\n');
  nativeWrite(1, 'plain\n');
  await Future<void>.delayed(const Duration(milliseconds: 80));
  await h.stop();
  check(h.history.any((l) => l.text == 'TAG:hello' && l.source == 'tagged'),
      'classifier tagged the matching line');
  check(h.history.any((l) => l.text == 'plain' && l.source == null),
      'classifier left the non-matching line null');

  stderr.writeln('== I. multi-byte UTF-8 split across writes ==');
  final iCap = await Stdio.start();
  final snow = utf8.encode('snow☃man'); // ☃ is 3 bytes (E2 98 83)
  nativeWriteBytes(1, snow.sublist(0, 5)); // splits mid-☃
  nativeWriteBytes(1, [...snow.sublist(5), 0x0A]);
  await Future<void>.delayed(const Duration(milliseconds: 80));
  await iCap.stop();
  check(iCap.history.any((l) => l.text == 'snow☃man'),
      'codepoint reassembled across the read boundary');

  stderr.writeln('== J. capture() restores + releases even when body throws ==');
  var jThrew = false;
  try {
    await Stdio.capture(() {
      print('pre-throw-line');
      throw StateError('boom');
    });
  } on StateError catch (e) {
    jThrew = e.message == 'boom';
  }
  check(jThrew, 'body exception propagated to the caller');
  // If the redirect leaked, this start() would throw StateError(busy); if fd
  // 1/2 still pointed at the dead pipes, the capture below would misbehave —
  // and the harness's own post-throw stderr reporting would vanish.
  final j2 = await Stdio.capture(() => print('post-throw-line'));
  check(j2.out.contains('post-throw-line'),
      'capture fully usable again after the throw');

  stderr.writeln('== K. bad mirror path fails cleanly at start() ==');
  // An existing FILE as the mirror's parent "directory" → open must fail.
  final kBlocker = File('${Directory.systemTemp.path}/stdio_capture_blocker')
    ..writeAsStringSync('x');
  var kThrew = false;
  try {
    await Stdio.start(mirrorToFile: File('${kBlocker.path}/nope.log'));
  } catch (_) {
    kThrew = true;
  }
  check(kThrew, 'start() threw instead of killing the reader silently');
  final k2 = await Stdio.capture(
      () => nativeWrite(1, 'after-mirror-fail\n'));
  check(k2.out.contains('after-mirror-fail'),
      'rolled back cleanly: capture usable again');
  kBlocker.deleteSync();

  stderr.writeln('== L. stop() is idempotent + concurrent-safe ==');
  final l = await Stdio.start();
  nativeWrite(1, 'l-line\n');
  await Future<void>.delayed(const Duration(milliseconds: 80));
  await Future.wait([l.stop(), l.stop()]); // concurrent
  await l.stop(); // and again after completion
  check(l.history.any((x) => x.text == 'l-line'),
      'double/concurrent stop OK, history intact');

  stderr.writeln('== M. argument validation ==');
  var mThrew = false;
  try {
    await Stdio.start(historyLines: 0);
  } on ArgumentError {
    mThrew = true;
  }
  var mReusable = false;
  try {
    final m2 = await Stdio.start();
    await m2.stop();
    mReusable = true;
  } catch (_) {}
  check(mThrew && mReusable,
      'historyLines: 0 → ArgumentError, and _busy not leaked by the throw');

  stderr.writeln('== N. newline-less flood is bounded (split, not dropped) ==');
  final n = await Stdio.start();
  nativeWriteBytes(1, List<int>.filled(1024 * 1024, 0x78)); // 1 MiB, no \n
  nativeWrite(1, '\n');
  await Future<void>.delayed(const Duration(milliseconds: 100));
  final nRes = await n.stop();
  final xBytes = nRes.lines
      .where((l) => l.stream == StdStream.out)
      .fold<int>(0, (s, l) => s + l.bytes.length);
  final maxLen = nRes.lines
      .map((l) => l.bytes.length)
      .fold<int>(0, (m, len) => len > m ? len : m);
  check(xBytes == 1024 * 1024, 'every byte delivered exactly once ($xBytes)');
  check(maxLen <= 64 * 1024, 'no line exceeds the 64 KiB cap (max $maxLen)');

  stderr.writeln('== O. pause()/resume(): terminal-handoff window ==');
  final o = await Stdio.start();
  print('o-before-pause');
  nativeWrite(1, 'o-native-before\n');
  await Future<void>.delayed(const Duration(milliseconds: 80));
  await o.pause();
  check(o.isPaused, 'isPaused true after pause()');
  // These land on the REAL stdout (the harness asserts they surface on the
  // subprocess's stdout, not in the transcript) — including a child spawned
  // with inheritStdio, which must inherit the real descriptors mid-pause.
  print('PAUSE-WINDOW-DIRECT-print');
  nativeWrite(1, 'PAUSE-WINDOW-DIRECT-native\n');
  final oChild = await Process.start('sh', ['-c', 'echo PAUSE-WINDOW-CHILD'],
      mode: ProcessStartMode.inheritStdio);
  await oChild.exitCode;
  await stdout.flush();
  await o.pause(); // idempotent
  await o.resume();
  check(!o.isPaused, 'isPaused false after resume()');
  await o.resume(); // idempotent
  print('o-after-resume');
  nativeWrite(1, 'o-native-after\n');
  await Future<void>.delayed(const Duration(milliseconds: 80));
  final oRes = await o.stop();
  check(
      oRes.out.contains('o-before-pause') &&
          oRes.out.contains('o-native-before'),
      'pre-pause lines captured');
  check(
      oRes.out.contains('o-after-resume') &&
          oRes.out.contains('o-native-after'),
      'post-resume lines captured');
  check(!oRes.out.contains('PAUSE-WINDOW'),
      'pause-window lines NOT captured (went to the real terminal)');
  var oThrew = false;
  try {
    await o.pause();
  } on StateError {
    oThrew = true;
  }
  check(oThrew, 'pause() after stop() throws StateError');

  // This must appear on the REAL terminal — proof restore worked.
  stderr.writeln('== restore proof: this line is on the real terminal ==');
  stderr.writeln(_failures == 0
      ? '\nALL CHECKS PASSED ✓'
      : '\n$_failures CHECK(S) FAILED ✗');
  exit(_failures == 0 ? 0 : 1);
}
