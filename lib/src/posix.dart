// POSIX FFI foundation: the ~dozen syscalls the package needs, plus the two
// structs (`pollfd`, `winsize`), platform-specific constants, and EINTR-safe /
// close-on-exec-aware wrappers. Everything above this file is pure Dart.
//
// Loaded per-isolate via [DynamicLibrary.process] — the reader isolate looks
// these up itself. Linux + macOS only (the package is POSIX-only by design).

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// ─── raw bindings ───────────────────────────────────────────────────────────

final DynamicLibrary _libc = DynamicLibrary.process();

final int Function(int) _dup =
    _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('dup');
final int Function(int, int) _dup2 = _libc
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>('dup2');
final int Function(Pointer<Int32>) _pipe = _libc.lookupFunction<
    Int32 Function(Pointer<Int32>), int Function(Pointer<Int32>)>('pipe');
final int Function(int, Pointer<Uint8>, int) _read = _libc.lookupFunction<
    IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
    int Function(int, Pointer<Uint8>, int)>('read');
final int Function(int, Pointer<Uint8>, int) _write = _libc.lookupFunction<
    IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
    int Function(int, Pointer<Uint8>, int)>('write');
final int Function(int) _close =
    _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('close');
// int fcntl(int fd, int cmd, int arg) — variadic in C, but our calls pass one
// int arg, so a fixed 3-arg signature is ABI-correct here.
final int Function(int, int, int) _fcntl = _libc.lookupFunction<
    Int32 Function(Int32, Int32, Int32), int Function(int, int, int)>('fcntl');
// int open(const char* path, int flags, mode_t mode)
final int Function(Pointer<Utf8>, int, int) _open = _libc.lookupFunction<
    Int32 Function(Pointer<Utf8>, Int32, Uint32),
    int Function(Pointer<Utf8>, int, int)>('open');
final int Function(int) _isatty =
    _libc.lookupFunction<Int32 Function(Int32), int Function(int)>('isatty');
// int poll(struct pollfd* fds, nfds_t nfds, int timeout) — nfds passed as
// IntPtr so a tiny value is correct whether nfds_t is 32- or 64-bit.
final int Function(Pointer<PollFd>, int, int) _poll = _libc.lookupFunction<
    Int32 Function(Pointer<PollFd>, IntPtr, Int32),
    int Function(Pointer<PollFd>, int, int)>('poll');
// int ioctl(int fd, unsigned long request, void* arg)
final int Function(int, int, Pointer<Void>) _ioctl = _libc.lookupFunction<
    Int32 Function(Int32, UnsignedLong, Pointer<Void>),
    int Function(int, int, Pointer<Void>)>('ioctl');

// errno is thread-local; these return a pointer to it. Different symbol per OS.
final Pointer<Int32> Function() _errnoLocation = () {
  final name = Platform.isMacOS ? '__error' : '__errno_location';
  return _libc.lookupFunction<Pointer<Int32> Function(),
      Pointer<Int32> Function()>(name);
}();

int get errno => _errnoLocation().value;

// ─── structs ────────────────────────────────────────────────────────────────

/// `struct pollfd { int fd; short events; short revents; }`
final class PollFd extends Struct {
  @Int32()
  external int fd;
  @Int16()
  external int events;
  @Int16()
  external int revents;
}

/// `struct winsize { unsigned short ws_row, ws_col, ws_xpixel, ws_ypixel; }`
final class WinSize extends Struct {
  @Uint16()
  external int row;
  @Uint16()
  external int col;
  @Uint16()
  external int xpixel;
  @Uint16()
  external int ypixel;
}

// ─── constants (platform-specific where they differ) ────────────────────────

final bool _mac = Platform.isMacOS;

const int eintr = 4; // EINTR — same on Linux + macOS
final int eagain = _mac ? 35 : 11; // EAGAIN / EWOULDBLOCK

// poll() event flags — identical on Linux + macOS.
const int pollIn = 0x0001;
const int pollErr = 0x0008;
const int pollHup = 0x0010;
const int pollNval = 0x0020;

// fcntl commands — identical.
const int fGetfd = 1;
const int fSetfd = 2;
const int fGetfl = 3;
const int fSetfl = 4;
const int fdCloexec = 1;

// O_NONBLOCK — differs between macOS and Linux.
final int oNonBlock = _mac ? 0x0004 : 0x800;

// open() flags — these DIFFER between macOS and Linux.
final int oWronly = 1; // same
final int oCreat = _mac ? 0x0200 : 0x40;
final int oTrunc = _mac ? 0x0400 : 0x200;
final int oAppend = _mac ? 0x0008 : 0x400;

// ioctl request to read the window size — differs.
final int tiocgwinsz = _mac ? 0x40087468 : 0x5413;

// ─── safe wrappers ──────────────────────────────────────────────────────────

/// Retries on EINTR. [op] returns the syscall result; negative means error.
int _retry(int Function() op) {
  while (true) {
    final r = op();
    if (r >= 0 || errno != eintr) return r;
  }
}

int dup(int fd) => _retry(() => _dup(fd));
int dup2(int oldFd, int newFd) => _retry(() => _dup2(oldFd, newFd));
int closeFd(int fd) => _retry(() => _close(fd));
int isatty(int fd) => _isatty(fd);
int poll(Pointer<PollFd> fds, int n, int timeoutMs) =>
    _retry(() => _poll(fds, n, timeoutMs));

/// A single `read()`, retrying EINTR. Returns bytes read (0 = EOF, <0 = error).
int readFd(int fd, Pointer<Uint8> buf, int len) =>
    _retry(() => _read(fd, buf, len));

/// Writes ALL of [bytes] to [fd], looping over partial writes and EINTR. A short
/// write to a terminal would otherwise truncate a frame. Throws on hard error.
void fdWriteAll(int fd, List<int> bytes) {
  if (bytes.isEmpty) return;
  final n = bytes.length;
  final buf = malloc<Uint8>(n);
  try {
    buf.asTypedList(n).setAll(0, bytes);
    var off = 0;
    while (off < n) {
      final w = _write(fd, buf + off, n - off);
      if (w > 0) {
        off += w;
      } else if (w < 0 && errno == eintr) {
        continue;
      } else if (w < 0 && errno == eagain) {
        continue; // blocking fd shouldn't EAGAIN, but be defensive
      } else {
        throw StdioCaptureException('write(fd=$fd) failed: errno=$errno');
      }
    }
  } finally {
    malloc.free(buf);
  }
}

/// Creates a pipe, returning `(readFd, writeFd)`. Throws on failure.
(int, int) makePipe() {
  final pair = malloc<Int32>(2);
  try {
    final rc = _pipe(pair);
    if (rc != 0) {
      throw StdioCaptureException('pipe() failed: errno=$errno');
    }
    return (pair[0], pair[1]);
  } finally {
    malloc.free(pair);
  }
}

/// Sets the close-on-exec flag so children don't inherit [fd]. We set this on
/// our saved-terminal fd and all pipe fds; the redirected fd 1/2 deliberately
/// do NOT get it (children should inherit them, that's how subprocess capture
/// works — dup2 clears CLOEXEC on its target).
void setCloexec(int fd) {
  final flags = _fcntl(fd, fGetfd, 0);
  if (flags < 0) return; // best-effort
  _fcntl(fd, fSetfd, flags | fdCloexec);
}

/// Adds O_NONBLOCK to [fd]'s file status flags so reads return EAGAIN instead of
/// blocking. Used on the reader's pipe read ends so it can fully drain.
void setNonBlocking(int fd) {
  final flags = _fcntl(fd, fGetfl, 0);
  if (flags < 0) return; // best-effort
  _fcntl(fd, fSetfl, flags | oNonBlock);
}

/// Opens [path] for writing (append or truncate), returning its fd.
///
/// The file is created (and truncated, when not appending) via `dart:io` first,
/// then opened `O_WRONLY` WITHOUT `O_CREAT`. That deliberately avoids passing
/// `open()`'s variadic `mode` argument: `open` is variadic in C, and a
/// fixed-arity FFI call passes the mode in a register while the callee reads it
/// from the varargs area — giving the created file a garbage mode on arm64.
int openForWrite(String path, {required bool append}) {
  final f = File(path);
  if (!f.existsSync()) {
    f.createSync(recursive: true);
  } else if (!append) {
    f.writeAsBytesSync(const <int>[]); // truncate
  }
  final cPath = path.toNativeUtf8();
  try {
    final flags = oWronly | (append ? oAppend : oTrunc);
    final fd = _retry(() => _open(cPath.cast(), flags, 0));
    if (fd < 0) {
      throw StdioCaptureException('open("$path") failed: errno=$errno');
    }
    return fd;
  } finally {
    malloc.free(cPath);
  }
}

/// Reads the terminal size of [fd] via `ioctl(TIOCGWINSZ)`, or null if it isn't
/// a terminal / the call fails.
(int cols, int rows)? terminalSize(int fd) {
  final ws = malloc<WinSize>();
  try {
    final rc = _ioctl(fd, tiocgwinsz, ws.cast());
    if (rc != 0) return null;
    final w = ws.ref;
    if (w.col == 0 && w.row == 0) return null;
    return (w.col, w.row);
  } finally {
    malloc.free(ws);
  }
}

class StdioCaptureException implements Exception {
  StdioCaptureException(this.message);
  final String message;
  @override
  String toString() => 'StdioCaptureException: $message';
}
