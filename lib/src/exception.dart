/// Thrown when a low-level stdio operation fails: a syscall error while
/// setting up or tearing down a capture/redirect (`dup`/`pipe`/`open`/
/// `fcntl`), a failed write to the saved terminal fd, or an internal
/// invariant the package could not uphold (e.g. the reader isolate's
/// non-blocking mode not taking, or its `poll()` failing persistently — the
/// latter surfaces on `Stdio.readerError` rather than being thrown).
///
/// Catch it around `Stdio.start`/`Stdio.capture`/`Stdio.redirectToFile` when
/// you want to degrade gracefully on exotic descriptor setups; a plain
/// `StateError` (not this type) signals the API-misuse cases, like starting
/// a second capture.
final class StdioException implements Exception {
  /// Creates an exception with a human-readable [message].
  const StdioException(this.message);

  /// What failed, including the failing syscall's `errno` where applicable.
  final String message;

  @override
  String toString() => 'StdioException: $message';
}
