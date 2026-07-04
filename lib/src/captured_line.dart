import 'dart:convert';
import 'dart:typed_data';

/// Which standard stream a line came from.
enum StdStream { out, err }

/// One captured line of output. Bytes are the source of truth — native output
/// is not guaranteed UTF-8 — and [text] is a lazily-decoded, replacement-safe
/// convenience. Instances cross the reader-isolate boundary, so every field is
/// sendable and [text] decodes on first access in whichever isolate reads it.
final class CapturedLine {
  CapturedLine({
    required this.rawBytes,
    required this.stream,
    required this.at,
    this.source,
  });

  /// The line's bytes, newline stripped.
  final Uint8List rawBytes;

  /// stdout or stderr (kept distinct by the two-pipe topology).
  final StdStream stream;

  /// When the reader assembled the line.
  final DateTime at;

  /// A subprocess / classifier tag, if known. Null for the plain in-process
  /// stream until a classifier or [adopt]/[startProcess] supplies one.
  final String? source;

  String? _text;

  /// The decoded line (UTF-8 with replacement), computed once.
  String get text => _text ??= utf8.decode(rawBytes, allowMalformed: true);

  @override
  String toString() => text;
}
