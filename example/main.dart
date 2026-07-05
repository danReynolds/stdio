// The three entry points of package:stdio.
//
// Run: dart run example/main.dart
// (Everything here uses Dart writes for simplicity — the whole point of the
// package is that native/FFI `write(1|2)` and child-process output are
// captured exactly the same way.)
import 'dart:io';

import 'package:stdio/stdio.dart';

Future<void> main() async {
  // ── 1. Scoped: capture exactly one body, get the transcript ──────────────
  final cap = await StdioCapture.capture(() {
    print('hello from stdout');
    stderr.writeln('and from stderr');
  });
  print('captured ${cap.lines.length} lines');
  print('stdout side: ${cap.out}');
  print('stderr side: ${cap.err}');

  // ── 2. Session: live streams + history + the real terminal ───────────────
  final capture = await StdioCapture.start(
    classify: (l) => l.text.startsWith('[db]') ? 'db' : null,
  );
  final seen = <String>[];
  capture.output.listen(
      (l) => seen.add('${l.stream.name}${l.source == null ? '' : '/${l.source}'}: ${l.text}'));

  print('[db] opened');            // tagged 'db' by the classifier
  stderr.writeln('plain stderr');  // untagged

  // The saved terminal writes THROUGH the capture, to the real screen:
  capture.terminal.writeln('(this line skips the capture entirely)');

  final result = await capture.stop(); // restore fd 1/2 + full transcript
  print('live listener saw: $seen');
  print('history kept ${result.lines.length} lines');

  // ── 3. Redirect: no capture — point fd 1/2 at a file and walk away ───────
  final log = File('${Directory.systemTemp.path}/stdio_example.log');
  final redirect = await StdioCapture.redirectToFile(log);
  print('this goes to the file, not the screen');
  stderr.writeln('this too, in exact write order');
  await stdout.flush();
  await redirect.stop();
  print('log file contents:\n${log.readAsStringSync()}');
  log.deleteSync();
}
