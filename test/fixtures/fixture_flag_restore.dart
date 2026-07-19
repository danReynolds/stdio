// B1 pinning fixture: O_NONBLOCK must not leak onto the original fd 1/2 file
// descriptions. The mirror-to-original path sets O_NONBLOCK on the saved fds;
// the flag lives on the open file DESCRIPTION, which stop()'s dup2 hands back
// to fd 1/2 — so without a restore, post-stop writes can EAGAIN (and a tty
// target would leave the parent shell's stdout non-blocking after exit).
//
// Run as a subprocess (it redirects the process's own fd 1/2). Reports on
// stderr after stop(); exit 0 iff both fds' F_SETFL-settable status flags
// (O_NONBLOCK | O_APPEND) match the pre-start snapshot, in mirror mode AND
// plain mode. The comparison is masked because macOS's F_GETFL also exposes
// kernel-internal state bits (e.g. 0x10000, set by ANY write to the
// description) that F_SETFL cannot control — verified with a no-capture
// control probe.

import 'dart:io';

import 'package:stdio/src/posix.dart';
import 'package:stdio/stdio.dart';

Future<void> main() async {
  final settable = oNonBlock | oAppend;
  final rawBefore1 = fdGetFlags(1);
  final rawBefore2 = fdGetFlags(2);
  if (rawBefore1 < 0 || rawBefore2 < 0) {
    stderr.writeln('SKIP: F_GETFL failed (errno=$errno)');
    exit(2);
  }
  final before1 = rawBefore1 & settable;
  final before2 = rawBefore2 & settable;

  // Mirror-to-original mode — the path that sets O_NONBLOCK on the saved fds.
  final mirrored = await Stdio.start(mirrorToOriginal: true);
  print('during-mirrored-capture');
  // Give the reader isolate time to run its saved-fd prep (the flag set).
  await Future<void>.delayed(const Duration(milliseconds: 150));
  await mirrored.stop();
  final afterMirror1 = fdGetFlags(1) & settable;
  final afterMirror2 = fdGetFlags(2) & settable;

  // Plain mode — flags must be untouched here too.
  final plain = await Stdio.start();
  print('during-plain-capture');
  await Future<void>.delayed(const Duration(milliseconds: 80));
  await plain.stop();
  final afterPlain1 = fdGetFlags(1) & settable;
  final afterPlain2 = fdGetFlags(2) & settable;

  stderr.writeln('fd1 settable flags: before=$before1 '
      'afterMirror=$afterMirror1 afterPlain=$afterPlain1');
  stderr.writeln('fd2 settable flags: before=$before2 '
      'afterMirror=$afterMirror2 afterPlain=$afterPlain2');

  final ok = afterMirror1 == before1 &&
      afterMirror2 == before2 &&
      afterPlain1 == before1 &&
      afterPlain2 == before2 &&
      // The specific leak: O_NONBLOCK must be CLEAR after stop() (it was
      // clear before — fd 1/2 of a spawned process never start non-blocking).
      (fdGetFlags(1) & oNonBlock) == 0 &&
      (fdGetFlags(2) & oNonBlock) == 0;
  stderr.writeln(ok ? 'FLAGS-RESTORED' : 'FLAGS-LEAKED');
  exit(ok ? 0 : 1);
}
