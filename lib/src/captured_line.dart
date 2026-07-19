import 'dart:convert';
import 'dart:typed_data';

/// Which standard stream a line came from.
enum StdStream {
  /// Standard output (fd 1).
  out,

  /// Standard error (fd 2).
  err,
}

/// One captured line of output. Immutable.
///
/// Bytes are the source of truth — native output is not guaranteed UTF-8 —
/// and [text] is a lazily-decoded, replacement-safe convenience. Instances
/// cross the reader-isolate boundary, so every field is sendable and [text]
/// decodes on first access in whichever isolate reads it.
final class CapturedLine {
  CapturedLine({
    required this.bytes,
    required this.stream,
    required this.at,
    required this.seq,
    this.source,
  });

  /// The line's bytes, exactly as written: only the terminating `\n` is
  /// stripped. In particular a CRLF line still carries its `\r` here — byte
  /// fidelity is the contract; [text] is the view that tidies it.
  final Uint8List bytes;

  /// stdout or stderr (kept distinct by the two-pipe topology).
  final StdStream stream;

  /// When the reader assembled the line.
  final DateTime at;

  /// Monotonic per-session sequence number, assigned by the session (on the
  /// main isolate) as the line enters the transcript — consecutive across
  /// every delivered line, whatever its origin (fd capture, `startProcess`
  /// / `adopt` children, classifier-tagged or not).
  ///
  /// This is the robust stitch between `history` and a live stream
  /// subscription made *after* an `await`: drop stream lines with `seq` at or
  /// below the last history line's `seq` and you have every line exactly
  /// once. (Lines you construct yourself may pass any value.)
  final int seq;

  /// Best-effort origin tag: the `source:` passed to `startProcess`/`adopt`,
  /// or what the `classify` hook returned. Null for untagged in-process lines.
  final String? source;

  String? _text;

  /// The decoded line (UTF-8 with replacement), computed once. One trailing
  /// `\r` is stripped, so CRLF-terminated output (curl progress, Windows-y
  /// tools) reads clean — [bytes] still carries the `\r` untouched.
  String get text => _text ??= utf8.decode(
      (bytes.isNotEmpty && bytes.last == 0x0D)
          ? Uint8List.sublistView(bytes, 0, bytes.length - 1)
          : bytes,
      allowMalformed: true);

  @override
  String toString() => text;
}
