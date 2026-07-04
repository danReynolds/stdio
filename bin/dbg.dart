import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:stdio_capture/stdio_capture.dart';

final _write = DynamicLibrary.process().lookupFunction<
    IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
    int Function(int, Pointer<Uint8>, int)>('write');
void nativeWrite(int fd, String s) {
  final b = utf8.encode(s);
  final buf = malloc<Uint8>(b.length);
  buf.asTypedList(b.length).setAll(0, b);
  _write(fd, buf, b.length);
  malloc.free(buf);
}

Future<void> main() async {
  final dbg = File('${Directory.current.path}/dbg-out.txt');
  final cap = await StdioCapture.start();
  print('A-via-print');
  stdout.write('B-via-stdout-write\n');
  nativeWrite(1, 'C-via-native-1\n');
  stderr.writeln('D-via-stderr-writeln');
  nativeWrite(2, 'E-via-native-2\n');
  await stdout.flush();
  await stderr.flush();
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await cap.stop();

  final buf = StringBuffer()
    ..writeln('history has ${cap.history.length} lines, '
        'dropped ${cap.droppedLines}:');
  for (final l in cap.history) {
    buf.writeln('  [${l.stream.name}] ${l.text}');
  }
  dbg.writeAsStringSync(buf.toString());
  stderr.writeln('wrote ${dbg.path}');
}
