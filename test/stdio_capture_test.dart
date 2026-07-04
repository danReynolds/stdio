@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  // The library redirects the PROCESS's fd 1/2 — running it in-process would
  // capture the test runner's own output. So the full end-to-end suite lives in
  // bin/verify.dart and we run it as a subprocess, asserting it exits 0. It
  // covers: native + Dart capture on both streams with correct tags, no deadlock
  // under a 40k-line storm with the main isolate blocked, double-start throws,
  // divertToFile, mirror log, subprocess tagging, the classifier hook, multi-
  // byte reassembly, and clean restore.
  test('end-to-end verification harness passes (bin/verify.dart)', () async {
    final result = await Process.run(
      Platform.resolvedExecutable, // the dart VM
      ['run', 'bin/verify.dart'],
      workingDirectory: Directory.current.path,
    );
    expect(
      result.exitCode,
      0,
      reason: 'verify.dart failed. Output:\n${result.stderr}\n${result.stdout}',
    );
  });
}
