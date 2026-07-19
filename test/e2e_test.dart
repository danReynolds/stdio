// End-to-end pinning tests that must run OUTSIDE the test-runner process
// (they redirect the process's fd 1/2), each as its own subprocess fixture
// under test/fixtures/. Every fixture reports on stderr and exits 0 on
// success; the broad platform self-check remains bin/verify.dart.
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

Future<ProcessResult> runFixture(String name) => Process.run(
      Platform.resolvedExecutable,
      ['run', 'test/fixtures/$name.dart'],
      workingDirectory: Directory.current.path,
    );

void expectFixturePassed(ProcessResult r, String name) {
  expect(r.exitCode, 0,
      reason: '$name failed.\nstderr:\n${r.stderr}\nstdout:\n${r.stdout}');
}

void main() {
  test('B1: stop() restores the original fd 1/2 file-status flags '
      '(no O_NONBLOCK leak from mirrorToOriginal)', () async {
    final r = await runFixture('fixture_flag_restore');
    expectFixturePassed(r, 'fixture_flag_restore');
    expect(r.stderr, contains('FLAGS-RESTORED'));
  });

  test('mirrorToOriginal: raw byte-transparent mirror to the real fds, '
      'split-intact, with monotonic seq on delivered lines', () async {
    final r = await runFixture('fixture_mirror_to_original');
    expectFixturePassed(r, 'fixture_mirror_to_original');
    // The mirror writes to the REAL fd 1/2 — this harness's pipes.
    expect(r.stdout, contains('mirror-dart-line'),
        reason: 'assembled line must be mirrored to the real stdout');
    expect(r.stdout, contains('mirror-native-partial'),
        reason: 'a newline-less partial must pass through raw (split-intact)');
    expect(r.stderr, contains('mirror-err-line'),
        reason: 'fd 2 mirrors to the real stderr, keeping the split');
  });

  test('C4: saved-fd mirror overflow is counted in mirrorDroppedBytes',
      () async {
    // This harness deliberately does NOT drain the child's stdout until the
    // fixture reports — so the mirror target (our pipe) fills, the reader's
    // bounded carry overflows, and the drops must be counted.
    final proc = await Process.start(
      Platform.resolvedExecutable,
      ['run', 'test/fixtures/fixture_mirror_overflow.dart'],
      workingDirectory: Directory.current.path,
    );
    final stderrLines = proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .asBroadcastStream();
    final collected = <String>[];
    stderrLines.listen(collected.add);
    await stderrLines
        .firstWhere((l) => l.contains('OVERFLOW-RESULT'))
        .timeout(const Duration(seconds: 60));
    // Only now start draining stdout so the fixture can finish cleanly.
    unawaited(proc.stdout.drain<void>());
    final code = await proc.exitCode;
    expect(code, 0,
        reason: 'fixture_mirror_overflow failed:\n${collected.join('\n')}');
    expect(collected.join('\n'), contains('OVERFLOW-RESULT counted'));
  });

  test('C3: reader death restores fd 1/2 — post-death writes do not wedge',
      () async {
    final r = await runFixture('fixture_reader_death');
    expectFixturePassed(r, 'fixture_reader_death');
    expect(r.stderr, contains('READER-DEATH-OK'));
    expect(r.stdout, contains('POST-DEATH-MARKER'),
        reason: 'post-death output must land on the restored real stdout');
  });

  test('D1: droppedLines/droppedBytes are numerically exact '
      '(reader drops + history eviction sum to K - H)', () async {
    final r = await runFixture('fixture_drop_accuracy');
    expectFixturePassed(r, 'fixture_drop_accuracy');
    expect(r.stderr, contains('DROP-ACCURACY-OK'));
  });

  test('pause()/resume() vs concurrent stop(): no corruption, sane restore',
      () async {
    final r = await runFixture('fixture_pause_stop_race');
    expectFixturePassed(r, 'fixture_pause_stop_race');
    expect(r.stdout, contains('POST-RACE-STDOUT'),
        reason: 'fd 1 must be restored to the real stdout after the race');
  });

  test('C7: startProcess/adopt throw after stop(); drained future delivers',
      () async {
    final r = await runFixture('fixture_post_stop_use');
    expectFixturePassed(r, 'fixture_post_stop_use');
    expect(r.stderr, contains('POST-STOP-USE-OK'));
  });

  test('classify that throws: lines still delivered untagged, no credit burn',
      () async {
    final r = await runFixture('fixture_classify_throw');
    expectFixturePassed(r, 'fixture_classify_throw');
    expect(r.stderr, contains('CLASSIFY-THROW-OK'));
  });
}
