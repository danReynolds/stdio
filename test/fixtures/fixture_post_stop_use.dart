// C7 pinning fixture: startProcess()/adopt() after stop() must throw
// StateError instead of silently discarding the child's output — and, pre-
// stop, the CapturedProcess.drained future is the synchronization point for
// "every line delivered" (no sleeps).

import 'dart:io';

import 'package:stdio/stdio.dart';

Future<void> main() async {
  var failures = 0;
  void check(bool ok, String label) {
    stderr.writeln('${ok ? "  ok" : "  FAIL"}  $label');
    if (!ok) failures++;
  }

  final s = await Stdio.start();

  // drained: await it, then the lines must ALREADY be in history — no delay.
  // (Facts are gathered here but reported after stop(): stderr is captured
  // until then.)
  final child = await s.startProcess(
      'sh', ['-c', 'echo drained-out; echo drained-err >&2'],
      source: 'kid');
  await child.process.exitCode;
  await child.drained;
  final drainedOutDelivered = s.history.any((l) =>
      l.text == 'drained-out' &&
      l.source == 'kid' &&
      l.stream == StdStream.out);
  final drainedErrDelivered = s.history.any((l) =>
      l.text == 'drained-err' &&
      l.source == 'kid' &&
      l.stream == StdStream.err);

  // adopt() pre-stop returns the drain future too.
  final manual = await Process.start('sh', ['-c', 'echo adopted-line']);
  await s.adopt(manual, source: 'manual');
  final adoptDelivered =
      s.history.any((l) => l.text == 'adopted-line' && l.source == 'manual');

  await s.stop();

  check(drainedOutDelivered, 'drained ⇒ child stdout already delivered');
  check(drainedErrDelivered, 'drained ⇒ child stderr already delivered');
  check(adoptDelivered, 'adopt() drain future delivers');

  var startThrew = false;
  try {
    await s.startProcess('sh', ['-c', 'echo lost'], source: 'late');
  } on StateError {
    startThrew = true;
  }
  check(startThrew, 'startProcess() after stop() throws StateError');

  final orphan = await Process.start('sh', ['-c', 'echo orphan']);
  var adoptThrew = false;
  try {
    await s.adopt(orphan, source: 'late');
  } on StateError {
    adoptThrew = true;
  }
  check(adoptThrew, 'adopt() after stop() throws StateError');
  // Don't leak the orphan: drain + reap it.
  orphan.stdout.drain<void>();
  orphan.stderr.drain<void>();
  await orphan.exitCode;

  stderr.writeln(failures == 0 ? 'POST-STOP-USE-OK' : 'POST-STOP-USE-FAILED');
  exit(failures == 0 ? 0 : 1);
}
