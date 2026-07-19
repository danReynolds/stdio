// Unit tests for the sink layer, written against a temp-file fd — they never
// touch the test runner's fd 1/2 (house rule).

import 'dart:convert';
import 'dart:io';

import 'package:stdio/src/posix.dart';
import 'package:stdio/stdio.dart';
import 'package:test/test.dart';

void main() {
  late File file;
  late int fd;

  setUp(() {
    file = File('${Directory.systemTemp.path}/'
        'stdio_sink_test_${DateTime.now().microsecondsSinceEpoch}');
    fd = openForWrite(file.path, append: false);
  });

  tearDown(() {
    closeFd(fd);
    if (file.existsSync()) file.deleteSync();
  });

  test('writeln honors lineTerminator; payload newlines pass through (D10)',
      () {
    final sink = StdoutTerminalSink(fd)..lineTerminator = '\r\n';
    sink.writeln('a\nb');
    sink.write('tail');
    expect(file.readAsStringSync(), 'a\nb\r\ntail',
        reason: 'ONLY the appended terminator is translated — the payload '
            "'\\n' goes through untouched (byte-transparent sink)");
  });

  test('writeln defaults to \\n', () {
    StdoutTerminalSink(fd).writeln('x');
    expect(file.readAsStringSync(), 'x\n');
  });

  test('write/writeAll/writeCharCode/add round-trip bytes exactly', () async {
    final sink = StdoutTerminalSink(fd);
    sink.write('a');
    sink.writeAll(['b', 'c'], '-');
    sink.writeCharCode(0x64); // d
    sink.add(utf8.encode('☃'));
    await sink.flush(); // no-op, but part of the contract
    await sink.close(); // must NOT close the fd (owned by the session)
    sink.write('!'); // still writable after close()
    expect(file.readAsStringSync(), 'ab-cd☃!');
  });

  test('encoding is honored and mutable', () {
    final sink = StdoutTerminalSink(fd, encoding: latin1);
    sink.write('é'); // one byte in latin-1
    expect(file.readAsBytesSync(), [0xE9]);
  });
}
