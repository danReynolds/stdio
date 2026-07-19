// Regression fixture for the Jul 5 hardening: pause()/resume() racing a
// concurrent stop(). The flush `await`s inside pause()/resume() open a gap
// where stop() can begin teardown; the late dup2 must NOT hit closed/reused
// descriptors — pause()/resume() either complete before teardown or throw
// StateError, and afterwards fd 1/2 are correctly restored either way.

import 'dart:io';

import 'package:stdio/stdio.dart';

Future<void> main() async {
  var failures = 0;
  void check(bool ok, String label) {
    stderr.writeln('${ok ? "  ok" : "  FAIL"}  $label');
    if (!ok) failures++;
  }

  // Round 1: pause() and stop() issued in the same synchronous turn.
  final s1 = await Stdio.start();
  print('r1-captured');
  final pauseF = s1.pause();
  final stopF = s1.stop();
  var pauseThrew = false;
  try {
    await pauseF;
  } on StateError {
    pauseThrew = true; // stop() won the race — the documented outcome
  }
  final cap1 = await stopF;
  check(cap1.lines.any((l) => l.text == 'r1-captured'),
      'round 1: transcript intact (pause threw: $pauseThrew)');

  // Round 2: resume() racing stop() from the paused state.
  final s2 = await Stdio.start();
  print('r2-captured');
  await s2.pause();
  final resumeF = s2.resume();
  final stop2F = s2.stop();
  var resumeThrew = false;
  try {
    await resumeF;
  } on StateError {
    resumeThrew = true;
  }
  await stop2F;
  check(true, 'round 2: resume-vs-stop survived (resume threw: $resumeThrew)');

  // Round 3: stop() while cleanly paused (the documented-safe combination).
  final s3 = await Stdio.start();
  print('r3-captured');
  await s3.pause();
  final cap3 = await s3.stop();
  check(cap3.lines.any((l) => l.text == 'r3-captured'),
      'round 3: stop while paused keeps the transcript');

  // Post-conditions for all rounds: no session leaked the busy flag, and fd
  // 1/2 point at the real stdout/stderr again.
  check(!Stdio.anyActive, 'no session left active');
  final s4 = await Stdio.capture(() => print('post-race-capture'));
  check(s4.out.contains('post-race-capture'),
      'a fresh capture still works after the races');

  print('POST-RACE-STDOUT'); // must reach the harness's real stdout pipe
  await stdout.flush();
  stderr.writeln(failures == 0 ? 'PAUSE-STOP-RACE-OK' : 'PAUSE-STOP-RACE-FAILED');
  exit(failures == 0 ? 0 : 1);
}
