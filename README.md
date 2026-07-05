# stdio

File-descriptor-level capture and redirection of **stdout/stderr** for Dart —
including the output that native/FFI code and child processes write straight
to the descriptors, bypassing Dart's stream objects entirely. POSIX (Linux +
macOS).

It's the Dart analog of Python's [`wurlitzer`](https://github.com/minrk/wurlitzer):
`dup2` moves the OS file descriptors 1 and 2 themselves, so it catches *every*
writer in the process — Dart `print`, a C library's `fprintf(stderr, …)`, a Go
runtime's `log`, a raw `write(1, …)`, and children that inherit the
descriptors — while handing you back a live handle to the real terminal.

## Why not just replace `stdout`?

Because a managed runtime and a C/Go library loaded into it **share the same
underlying file descriptor**, but native code holds its own `FILE*`/runtime
writer, not Dart's `stdout` object. Replacing Dart's `stdout` (or a zone's
`print`, or `IOOverrides`) cannot, in principle, catch native output — it
writes to the descriptor, underneath the language. The only thing that catches
it is moving the descriptor itself. That's what this package does.

The motivating case: a full-screen TUI (whose frames *are* fd 1) that embeds
native libraries. One stray native log line lands in the middle of a rendered
frame and corrupts the display — unless the descriptor is captured first.

## Quick start

Three entry points, shaped like `Process.start` / `Process.run`:

```dart
import 'package:stdio/stdio.dart';

// 1. Scoped — capture exactly one body, get the transcript:
final cap = await StdioCapture.capture(() {
  greetFromC();          // C printf → write(1), invisible to zones
  print('and dart');
});
print(cap.out);          // both lines; cap.err / cap.lines for more

// 2. Session — capture until you stop:
final capture = await StdioCapture.start();
capture.output.listen((l) => log('${l.stream.name}: ${l.text}'));
// … run the noisy code …
final result = await capture.stop();   // restores fd 1/2, returns the transcript

// 3. Redirect — no capture, just point fd 1/2 at a file:
final redirect = await StdioCapture.redirectToFile(File('service.log'));
// … native noise now lands in the file, in exact merged order …
await redirect.stop();
```

## The TUI recipe

The session handle keeps a dup of the *original* fd 1 — the real terminal —
so your UI renders while everything else is captured:

```dart
final capture = await StdioCapture.start(
  mirrorToFile: File('debug.log'),   // durable copy of every captured line
);

capture.history.forEach(showInConsole);      // lines from before you subscribed
capture.output.listen(showInConsole);        // live, tagged stdout/stderr

// Render through the saved terminal:
myDriver.write(frame, to: capture.terminal);          // an IOSink
// …or, for a driver API that wants a concrete Stdout:
runApp(driver: PosixDriver(stdoutOverride: capture.terminalStdout));

await capture.stop();

// Terminal handoff (an $EDITOR, a pager): point fd 1/2 back at the real
// terminal for the child, then re-capture — the session stays live:
await capture.pause();
await (await Process.start(editor, [file], mode: ProcessStartMode.inheritStdio)).exitCode;
await capture.resume();
```

Children too: `capture.startProcess('worker', [], source: 'worker')` merges a
child's output with every line tagged `source: 'worker'` — or `adopt()` a
process you started yourself. Children spawned with `inheritStdio` are
captured automatically (they inherit the redirected descriptors), just
untagged.

## What it does / doesn't

- **Does:** capture (`start`/`capture`) and redirect (`redirectToFile`) of
  **stdout and stderr**, at the descriptor level; line assembly with tags,
  history, and drop accounting; a saved-terminal render handle; child-process
  tagging.
- **Doesn't touch stdin.** fd 0 is deliberately left alone — a TUI keeps
  reading keys, a REPL keeps its prompt. (fd-level std*in* injection — the
  mirror image, for feeding scripted input in tests — is a natural future
  addition; it just isn't here yet.)
- **Doesn't parse or colorize.** Lines are delivered as bytes (`.bytes`) with
  a lazy UTF-8 `.text` view; ANSI codes pass through untouched.
- **No Windows, no web.** See Platform below.

## Semantics & guarantees

- **Backpressure is bounded and never blocks.** A dedicated reader isolate
  drains the pipes continuously — even while your main isolate is stalled — so
  a writer can't block on a full pipe. Under a storm it drops oldest (counted
  via `droppedLines` / `droppedBytes`); it never OOMs or deadlocks.
- **Lines are bounded too.** A writer that never emits a newline can't grow
  memory: runs longer than `maxLineBytes` (default 64 KiB) are delivered split
  into cap-sized pieces — split, not dropped.
- **Restore is explicit + best-effort.** `stop()` restores fd 1/2, and
  `capture()` calls it in a `finally`, so scoped exceptions restore too. The
  package deliberately installs **no signal handlers** (a library grabbing
  SIGINT would fight the app's own handling — TUIs own `^C`); if you exit on
  signals, wire your handler to call `stop()`. Nothing can restore after
  `SIGKILL`, `abort()`, or a segfault — but fd redirection is process-local,
  so a crash leaves the parent shell untouched.
- **One capture at a time.** fd redirection is process-global; a second
  `start()`/`capture()` throws `StateError`. Tests using `capture()` must run
  serially if they assert on process stdio.
- **Tag XOR exact cross-stream order.** Two pipes keep the stdout/stderr tag,
  so `stdout`/`stderr` are exact within each stream but the combined `output`
  is only *approximately* interleaved across streams. Faithful byte order is
  available where it's natural — `redirectToFile` merges both onto one file.
- **Bytes are the source of truth.** `CapturedLine.bytes` is primary; `.text`
  is a lazily-decoded (replacement-safe) convenience.
- **Tagged children ride the main event loop.** `startProcess`/`adopt` deliver
  through Dart streams on the main isolate — if main stalls, the *child* gets
  backpressured (its pipe fills), unlike fd 1/2 writers which the reader
  isolate drains regardless. An `inheritStdio` child gets the never-blocks
  guarantee instead, at the cost of arriving untagged.
- **Stopping under a live inherited child**: after `stop()` closes the pipes,
  a child still writing to its inherited fd 1/2 gets `EPIPE`/`SIGPIPE` on the
  next write — inherent to fd capture (wurlitzer behaves the same). Wind
  children down first when you can.
- **Don't pause a subscription.** A paused broadcast subscription buffers
  events unboundedly (Dart stream semantics). Slow consumers should sample
  `history` instead.
- **After `stop()`**, `terminal`/`terminalStdout` are invalid (the saved fd is
  closed), and a reader-isolate death during the session closes the line
  streams (listeners get `onDone`) with the cause on `readerError`.
- **`/dev/tty`-direct writes escape** (rare), and native stdio may
  block-buffer a `stdout` writer when it's redirected to a pipe (well-behaved
  tools detect the non-tty and switch to line buffering or plain logs).

## Platform

POSIX only — Linux and macOS, exercised on arm64 and x86-64. No Windows (a
`SetStdHandle`/`_dup2` port would be a separate implementation behind the same
API). No web (no file descriptors). Flutter desktop on macOS/Linux shares the
same VM and should work; mobile is untested, and Android/iOS system logging
mostly bypasses fd 1/2 anyway.

## Design

`dup(1)`/`dup(2)` save the original descriptors; two `pipe`s take fd 1 and fd
2 (`dup2`); a reader isolate polls both plus a self-pipe control channel
(credit + stop — flow control without an event loop, since the reader blocks
in `poll()`), assembles lines on `0x0A`, and ships credit-bounded batches to
the main isolate. `stop()` restores fd 1/2, then EOFs the reader, drains to
completion, then closes — in that order, so nothing in flight is lost and no
writer sees `EPIPE`. All FFI
(`dup`/`dup2`/`pipe`/`read`/`write`/`close`/`fcntl`/`ioctl`/`poll`/`isatty`/`open`),
one dependency (`package:ffi`).

Porting note learned the hard way: `open`, `fcntl`, and `ioctl` are
**variadic** in C. On arm64 macOS a fixed-arity FFI binding passes the third
argument in a register while the callee reads the varargs area of the stack —
so `F_SETFL` sets random flags and `TIOCGWINSZ` reads a garbage pointer,
intermittently. Variadic syscalls must be bound with `dart:ffi`'s `VarArgs`,
and `setNonBlocking` verifies the flag actually took (a silently-blocking read
end would defeat the reader's no-deadlock guarantee).

## Related work

- Python's [`wurlitzer`](https://github.com/minrk/wurlitzer) — the same
  fd-level technique, and the direct inspiration.
- Dart's zones / `IOOverrides` — capture Dart-level writes only; native and
  child output is invisible to them by construction.
- `package:posix` and friends expose raw `dup2`, but nothing in the ecosystem
  owned the whole problem (drain isolate, backpressure, restore ordering, line
  assembly, terminal handle) before this package.
