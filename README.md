# stdio_capture

File-descriptor-level capture of `stdout`/`stderr` for Dart — **including output
from native/FFI code and inherited subprocesses** that bypass Dart's stream
objects. POSIX (Linux + macOS).

It's the Dart analog of Python's [`wurlitzer`](https://github.com/minrk/wurlitzer):
it redirects the OS file descriptors 1 and 2 with `dup2`, so it catches *every*
writer in the process — Dart `print`, a C library's `fprintf(stderr, …)`, a Go
runtime's `log`, a raw `write(1, …)`, and children that inherit the descriptors
— while handing you back a live handle to the real terminal.

## Why not just replace `stdout`?

Because a managed runtime and a C/Go library loaded into it **share the same
underlying file descriptor**, but native code holds its own `FILE*`/runtime
writer, not Dart's `stdout` object. Replacing Dart's `stdout` (or a zone's
`print`, or `IOOverrides`) cannot, in principle, catch native output — it writes
straight to the descriptor, underneath the language. The only thing that catches
it is moving the descriptor itself. That's what this package does.

This matters for a full-screen TUI (whose frames *are* fd 1) that embeds native
libraries: a stray native log line would otherwise land in the middle of a
rendered frame and corrupt the display.

## Usage

### Long-lived capture (a TUI)

```dart
final capture = await StdioCapture.start();

// Per-stream — the subscription is the tag. Pair with `history` for output
// produced before you subscribed.
capture.history.forEach(render);
capture.stdout.listen(render);   // stdout lines
capture.stderr.listen(render);   // stderr lines
capture.listen(render);          // both, interleaved (each line keeps .stream)

// Render your UI through the REAL terminal (the saved dup of fd 1):
myDriver.write(frame, to: capture.terminal);        // a TerminalSink (IOSink)
// …or, for an API that wants a concrete Stdout:
myDriver.write(frame, to: capture.terminalStdout);

await capture.stop();            // restore fd 1/2
```

### Scoped (tests / the wurlitzer ergonomic)

```dart
final cap = await StdioCapture.collect(() {
  greetFromC();     // C printf → write(1) directly
  print('and dart');
});
expect(cap.out, contains('Hello from C'));   // the byte no other Dart package catches
```

### Direct redirect to a file (a headless service)

```dart
final divert = await StdioCapture.divertToFile(File('service.log'));
// … run the noisy code … native tsnet/sqlite output now goes to the file …
await divert.stop();
```

### Subprocess tagging & durable mirror

```dart
final capture = await StdioCapture.start(
  mirrorToFile: File('debug.log'),                 // a durable copy of everything
  classify: (l) => l.text.startsWith('DB') ? 'sqlite' : null, // best-effort tag
);
final child = await capture.startProcess('worker', ['--serve'], source: 'worker');
// the child's lines arrive tagged source: 'worker'
```

## Semantics & guarantees

- **Backpressure is bounded and never blocks.** A dedicated reader isolate drains
  the pipes continuously — even while your main isolate is stalled — so a writer
  can't block on a full pipe. Under a storm it drops oldest (counted via
  `droppedLines` / `droppedBytes`); it never OOMs or deadlocks.
- **Restore is best-effort.** fd 1/2 are restored on `stop()`, scoped exceptions,
  and catchable signals. It does **not** (cannot) restore after `SIGKILL`,
  `abort()`, or a segfault — but fd redirection is process-local, so a crash
  leaves the parent shell untouched.
- **One capture at a time.** fd redirection is process-global; a second
  `start()`/`collect()` throws `StateError`. Tests using `collect()` must run
  serially if they assert on process stdio.
- **Tag XOR exact cross-stream order.** Two pipes keep the stdout/stderr tag, so
  `stdout`/`stderr` are exact within each stream but the combined `listen` is
  only *approximately* interleaved across streams. Faithful byte-order is
  available where it's natural — `divertToFile` merges both onto one file.
- **Bytes are the source of truth.** `CapturedLine.rawBytes` is primary; `.text`
  is a lazily-decoded (replacement-safe) convenience.
- **Tagged children ride the main event loop.** `startProcess`/`adopt` deliver
  through Dart streams on the main isolate — if main stalls, the *child* gets
  backpressured (its pipe fills), unlike fd 1/2 writers which the reader
  isolate drains regardless. An `inheritStdio` child gets the never-blocks
  guarantee instead, at the cost of arriving untagged.
- **Stopping under a live inherited child**: after `stop()` closes the pipes, a
  child still writing to its inherited fd 1/2 gets `EPIPE`/`SIGPIPE` on the
  next write — inherent to fd capture (wurlitzer behaves the same). Wind
  children down first when you can.
- **Don't pause a subscription.** A paused broadcast subscription buffers
  events unboundedly (Dart stream semantics). Slow consumers should sample
  `history` instead.
- **After `stop()`**, `terminal`/`terminalStdout` are invalid (the saved fd is
  closed), and a reader-isolate death during the session is surfaced on
  `readerError` (delivery just stops; `stop()` still restores normally).
- **`/dev/tty`-direct writes escape** (rare), and native stdio may block-buffer a
  `stdout` writer when it's redirected to a pipe.

## Platform

POSIX only — Linux and macOS. No Windows (a `SetStdHandle`/`_dup2` port would be
a separate implementation behind the same API). No web (no file descriptors).

## Design

`dup(1)` saves the terminal; two `pipe`s take fd 1 and fd 2 (`dup2`); a reader
isolate polls both plus a self-pipe control channel (credit + stop — flow control
without an event loop the blocking `poll()` can't service), assembles lines on
`0x0A`, and ships credit-bounded batches to the main isolate. `stop()` restores
fd 1/2, then EOFs the reader, then closes — in that order, so no `EPIPE`. All FFI
(`dup`/`dup2`/`pipe`/`read`/`write`/`close`/`fcntl`/`ioctl`/`poll`/`isatty`/`open`),
one dependency (`package:ffi`).

Porting note learned the hard way: `open`, `fcntl`, and `ioctl` are **variadic**
in C. On arm64 macOS a fixed-arity FFI binding passes the third argument in a
register while the callee reads the varargs area of the stack — so `F_SETFL`
sets random flags and `TIOCGWINSZ` reads a garbage pointer, intermittently.
Variadic syscalls must be bound with `dart:ffi`'s `VarArgs`, and
`setNonBlocking` verifies the flag actually took (a silently-blocking read end
would defeat the reader's no-deadlock guarantee).
