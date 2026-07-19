// POSIX FFI foundation: the ~dozen syscalls the package needs, plus the two
// structs (`pollfd`, `winsize`), platform-specific constants, and EINTR-safe /
// close-on-exec-aware wrappers. Everything above this file is pure Dart.
//
// Loaded per-isolate via [DynamicLibrary.process] — the reader isolate looks
// these up itself. Linux + macOS only (the package is POSIX-only by design).

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

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
// int fcntl(int fd, int cmd, ...) — VARIADIC in C. On arm64 macOS variadic
// args are passed on the stack while a fixed-arity FFI signature passes them
// in registers, so the callee reads garbage — F_SETFL would set random flags
// (observed: O_NONBLOCK silently not taking, turning the reader's non-blocking
// drains into blocking reads). Same ABI trap as open()'s mode arg. The reads
// (F_GETFL/F_GETFD) take no third arg, so a fixed 2-arg binding is correct;
// the writes go through a VarArgs binding that uses the real varargs ABI.
final int Function(int, int) _fcntlGet = _libc.lookupFunction<
    Int32 Function(Int32, Int32), int Function(int, int)>('fcntl');
final int Function(int, int, int) _fcntlSet = _libc.lookupFunction<
    Int32 Function(Int32, Int32, VarArgs<(Int32,)>),
    int Function(int, int, int)>('fcntl');
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
// int ioctl(int fd, unsigned long request, ...) — variadic like fcntl; the
// pointer arg must travel via the varargs ABI (see the fcntl note above).
final int Function(int, int, Pointer<Void>) _ioctl = _libc.lookupFunction<
    Int32 Function(Int32, UnsignedLong, VarArgs<(Pointer<Void>,)>),
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
const int pollOut = 0x0004;
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

/// A single best-effort write pass: writes as much of [bytes] as the fd will
/// take RIGHT NOW (looping only over EINTR and partial progress), and returns
/// the number of bytes consumed — possibly 0 when a non-blocking fd is full
/// (EAGAIN). Returns -1 on hard error. Never blocks, never throws: the
/// caller owns the retry/carry/drop policy. This is the primitive for
/// mirroring captured output back to a saved fd from the reader isolate,
/// whose contract is that it can never block.
int fdWriteBest(int fd, Uint8List bytes) {
  if (bytes.isEmpty) return 0;
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
        return off; // fd full — caller carries the remainder
      } else {
        return -1; // hard error — caller disables the mirror
      }
    }
    return off;
  } finally {
    malloc.free(buf);
  }
}

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
        // The target is non-blocking and full (a TUI driver may have flipped
        // the tty to O_NONBLOCK — the flag lives on the shared open file
        // description, so our saved dup sees it too). Busy-retrying would spin
        // a core; block in poll() until writable instead.
        _awaitWritable(fd);
      } else {
        throw StdioException('write(fd=$fd) failed: errno=$errno');
      }
    }
  } finally {
    malloc.free(buf);
  }
}

/// Blocks until [fd] is writable. Used by [fdWriteAll] when a non-blocking
/// target returns EAGAIN.
void _awaitWritable(int fd) {
  final p = malloc<PollFd>();
  try {
    p.ref
      ..fd = fd
      ..events = pollOut
      ..revents = 0;
    _retry(() => _poll(p, 1, -1));
  } finally {
    malloc.free(p);
  }
}

/// Creates a pipe, returning `(readFd, writeFd)`. Throws on failure.
(int, int) makePipe() {
  final pair = malloc<Int32>(2);
  try {
    final rc = _pipe(pair);
    if (rc != 0) {
      throw StdioException('pipe() failed: errno=$errno');
    }
    return (pair[0], pair[1]);
  } finally {
    malloc.free(pair);
  }
}

/// Sets the close-on-exec flag so children don't inherit [fd]. We set this on
/// our saved-terminal fd and all pipe fds; the redirected fd 1/2 deliberately
/// do NOT get it (children should inherit them, that's how subprocess capture
/// works — dup2 clears CLOEXEC on its target). Best-effort: a leak into a
/// child is a hygiene issue, not a correctness one.
void setCloexec(int fd) {
  final flags = _fcntlGet(fd, fGetfd);
  if (flags < 0) return;
  _fcntlSet(fd, fSetfd, flags | fdCloexec);
}

/// Adds O_NONBLOCK to [fd]'s file status flags so reads return EAGAIN instead
/// of blocking, and VERIFIES it took. Throws on failure: the reader's drain
/// loop is only correct on non-blocking fds (a blocking read() would stall the
/// whole loop and reintroduce the writer deadlock this package exists to
/// prevent), so silent failure here must be fatal, not best-effort.
void setNonBlocking(int fd) {
  final flags = _fcntlGet(fd, fGetfl);
  if (flags < 0) {
    throw StdioException('fcntl(F_GETFL, fd=$fd) failed: errno=$errno');
  }
  _fcntlSet(fd, fSetfl, flags | oNonBlock);
  final after = _fcntlGet(fd, fGetfl);
  if (after < 0 || (after & oNonBlock) == 0) {
    throw StdioException(
        'fcntl(F_SETFL, fd=$fd) did not set O_NONBLOCK '
        '(flags $flags -> $after, errno=$errno)');
  }
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
      throw StdioException('open("$path") failed: errno=$errno');
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

class StdioException implements Exception {
  StdioException(this.message);
  final String message;
  @override
  String toString() => 'StdioException: $message';
}
