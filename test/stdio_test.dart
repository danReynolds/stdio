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
    // OS-level fd-restore regression check. This harness runs the subprocess
    // with SEPARATE stdout/stderr pipes, and verify.dart reports on stderr
    // AFTER many capture cycles. If any stop() mis-restored fd 2 (the classic
    // bug: restoring it from the saved fd 1), the report would land on
    // result.stdout instead — invisible on a terminal, where both fds point at
    // the same tty, which is exactly why this must be asserted here.
    expect(result.stderr, contains('ALL CHECKS PASSED'),
        reason: 'the report must arrive on the real stderr');
    expect(result.stdout, isNot(contains('ALL CHECKS PASSED')),
        reason: "report leaked onto stdout — fd 2 was restored to fd 1's "
            'target');
    // pause() semantics, asserted at the OS level: during the pause window,
    // Dart print, native write(1), AND an inheritStdio child must all land on
    // the REAL stdout (this harness's pipe), not in the capture.
    for (final marker in [
      'PAUSE-WINDOW-DIRECT-print',
      'PAUSE-WINDOW-DIRECT-native',
      'PAUSE-WINDOW-CHILD',
    ]) {
      expect(result.stdout, contains(marker),
          reason: '\$marker must surface on the real stdout during pause()');
    }
  });
}
