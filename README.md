# stdio

File-descriptor-level capture and redirection of **stdout/stderr** for Dart —
including the output that native/FFI code and child processes write straight to
the descriptors, bypassing Dart's stream objects entirely. POSIX (Linux +
macOS).

`dup2` moves the OS file descriptors 1 and 2 themselves, so it catches *every*
writer in the process — Dart `print`, a C library's `fprintf(stderr, …)`, a Go
runtime's `log`, a raw `write(1, …)`, and child processes that inherit the
descriptors. It's the Dart analog of Python's
[`wurlitzer`](https://github.com/minrk/wurlitzer).

```dart
import 'package:stdio/stdio.dart';

final cap = await Stdio.capture(() {
  greetFromC();       // C printf → write(1), invisible to zones/IOOverrides
  print('and dart');
});
print(cap.out);       // "hello from C\nand dart\n"
```

## Why not just replace `stdout`?

Because a managed runtime and a C/Go library loaded into it **share the same
underlying file descriptor**, but native code holds its own `FILE*`/runtime
writer, not Dart's `stdout` object. Replacing Dart's `stdout` (or a zone's
`print`, or `IOOverrides`) cannot, in principle, catch native output — it writes
to the descriptor, underneath the language. The only thing that catches it is
moving the descriptor itself. That's what this package does.

Where that matters:

- **Testing native code** — assert on what a C/Rust/Go dependency prints, or
  keep its chatter out of your test output.
- **Taming a noisy dependency** — reroute a library that logs to stderr into a
  file (or your own logger) without patching it.
- **Unified capture** — collect *everything* a process emits, subprocesses
  included, in one place for a log pipeline.
- **Interactive programs** — a full-screen app owns fd 1, so one stray native
  log line corrupts the display; capture it first and keep a clean channel to
  the terminal (see [Keeping a live terminal](#keeping-a-live-terminal)).

## Quick start

Three entry points, shaped like `Process.start` / `Process.run`:

```dart
import 'package:stdio/stdio.dart';

// 1. Scoped — capture exactly one body, get the transcript back:
final cap = await Stdio.capture(() {
  greetFromC();
  print('and dart');
});
print(cap.out);          // both lines; cap.err / cap.lines for more

// 2. Session — capture until you stop:
final capture = await Stdio.start();
capture.output.listen((l) => log('${l.stream.name}: ${l.text}'));
// … run the noisy code …
final result = await capture.stop();   // restores fd 1/2, returns the transcript

// 3. Redirect — no capture, just point fd 1/2 at a file:
final redirect = await Stdio.redirectToFile(File('service.log'));
// … native noise now lands in the file, in exact merged order …
await redirect.stop();
```

Lines arrive as bytes (`CapturedLine.bytes`) with a lazy, replacement-safe UTF-8
`.text` view, tagged stdout/stderr, plus `history` (what was captured before you
subscribed) and drop accounting. ANSI codes pass through untouched.

## Keeping a live terminal

A session keeps a dup of the *original* fd 1 — the real terminal — so you can
still write to it while everything else is captured. `capture.terminal` is an
`IOSink` onto that saved descriptor:

```dart
final capture = await Stdio.start(
  mirrorToFile: File('debug.log'),        // durable copy of every captured line
);

capture.output.listen((l) => showSomewhere(l));   // captured stdout/stderr
capture.terminal.write(renderedFrame);            // …still reaches the screen
```

To hand the terminal to a child process (an `$EDITOR`, a pager) and take it back
without ending the session — useful well beyond any UI:

```dart
await capture.pause();   // restore fd 1/2 to the real terminal for the child
await (await Process.start(
  editor, [file], mode: ProcessStartMode.inheritStdio,
)).exitCode;
await capture.resume();  // re-capture; the session stayed live throughout
```

Child processes you start through the session are tagged and merged:
`capture.startProcess('worker', [], source: 'worker')` labels every line with
`source: 'worker'`, or `adopt()` a process you started yourself. Children
spawned with `inheritStdio` are captured automatically (they inherit the
redirected descriptors), just untagged.

## What it does / doesn't

- **Does:** capture (`start` / `capture`) and redirect (`redirectToFile`) of
  **stdout and stderr** at the descriptor level; line assembly with tags,
  history, and drop accounting; a saved-terminal handle; child-process tagging.
- **Doesn't touch stdin.** fd 0 is left alone — an interactive program keeps
  reading input exactly as before. (fd-level std*in* injection — the mirror
  image, for feeding scripted input in tests — is a natural future addition; it
  just isn't here yet.)
- **Doesn't parse or colorize.** Lines are bytes with a lazy `.text` view; ANSI
  passes through.
- **No Windows, no web.** See [Platform](#platform).

## Semantics & guarantees

- **Backpressure is bounded and never blocks.** A dedicated reader isolate
  drains the pipes continuously — even while your main isolate is stalled — so a
  writer can't block on a full pipe. Under a storm it drops oldest (counted via
  `droppedLines` / `droppedBytes`); it never OOMs or deadlocks.
- **Lines are bounded too.** A writer that never emits a newline can't grow
  memory: runs longer than `maxLineBytes` (default 64 KiB) are delivered split
  into cap-sized pieces — split, not dropped.
- **Restore is explicit + best-effort.** `stop()` restores fd 1/2, and
  `capture()` calls it in a `finally`, so scoped exceptions restore too. The
  package deliberately installs **no signal handlers** (a library grabbing
  SIGINT would fight the app's own handling); if you exit on signals, wire your
  handler to call `stop()`. Nothing can restore after `SIGKILL`, `abort()`, or a
  segfault — but fd redirection is process-local, so a crash leaves the parent
  shell untouched.
- **One capture at a time.** fd redirection is process-global; a second
  `start()` / `capture()` throws `StateError`. Tests using `capture()` must run
  serially if they assert on process stdio.
- **Tag XOR exact cross-stream order.** Two pipes keep the stdout/stderr tag, so
  each stream is exact within itself but the combined `output` is only
  *approximately* interleaved across streams. Faithful byte order is available
  where it's natural — `redirectToFile` merges both onto one file.
- **Bytes are the source of truth.** `CapturedLine.bytes` is primary; `.text` is
  a lazily-decoded (replacement-safe) convenience.
- **Tagged children ride the main event loop.** `startProcess` / `adopt` deliver
  through Dart streams on the main isolate — if main stalls, the *child* gets
  backpressured (its pipe fills), unlike fd 1/2 writers which the reader isolate
  drains regardless. An `inheritStdio` child gets the never-blocks guarantee
  instead, at the cost of arriving untagged.
- **Stopping under a live inherited child**: after `stop()` closes the pipes, a
  child still writing to its inherited fd 1/2 gets `EPIPE` / `SIGPIPE` on the
  next write — inherent to fd capture (wurlitzer behaves the same). Wind children
  down first when you can.
- **Don't pause a subscription.** A paused broadcast subscription buffers events
  unboundedly (Dart stream semantics). Slow consumers should sample `history`.
- **After `stop()`**, `terminal` / `terminalStdout` are invalid (the saved fd is
  closed), and a reader-isolate death during the session closes the line streams
  (listeners get `onDone`) with the cause on `readerError`.
- **`/dev/tty`-direct writes escape** (rare), and native stdio may block-buffer a
  `stdout` writer when it's redirected to a pipe (well-behaved tools detect the
  non-tty and switch to line buffering or plain logs).

## Platform

POSIX only — Linux and macOS, exercised on arm64 and x86-64. No Windows (a
`SetStdHandle` / `_dup2` port would be a separate implementation behind the same
API). No web (no file descriptors). Flutter desktop on macOS/Linux shares the
same VM and should work; mobile is untested, and Android/iOS system logging
mostly bypasses fd 1/2 anyway.

## Design

`dup(1)` / `dup(2)` save the original descriptors; two `pipe`s take fd 1 and fd 2
(`dup2`); a reader isolate polls both plus a self-pipe control channel (credit +
stop — flow control without an event loop, since the reader blocks in `poll()`),
assembles lines on `0x0A`, and ships credit-bounded batches to the main isolate.
`stop()` restores fd 1/2, then EOFs the reader, drains to completion, then closes
— in that order, so nothing in flight is lost and no writer sees `EPIPE`. All FFI
(`dup` / `dup2` / `pipe` / `read` / `write` / `close` / `fcntl` / `ioctl` /
`poll` / `isatty` / `open`), one dependency (`package:ffi`).

Porting note learned the hard way: `open`, `fcntl`, and `ioctl` are **variadic**
in C. On arm64 macOS a fixed-arity FFI binding passes the third argument in a
register while the callee reads the varargs area of the stack — so `F_SETFL`
sets random flags and `TIOCGWINSZ` reads a garbage pointer, intermittently.
Variadic syscalls must be bound with `dart:ffi`'s `VarArgs`, and `setNonBlocking`
verifies the flag actually took (a silently-blocking read end would defeat the
reader's no-deadlock guarantee).

## Related work

- Python's [`wurlitzer`](https://github.com/minrk/wurlitzer) — the same fd-level
  technique, and the direct inspiration.
- Dart's zones / `IOOverrides` — capture Dart-level writes only; native and
  child output is invisible to them by construction.
- `package:posix` and friends expose raw `dup2`, but nothing in the ecosystem
  owned the whole problem (drain isolate, backpressure, restore ordering, line
  assembly, terminal handle) before this package.
