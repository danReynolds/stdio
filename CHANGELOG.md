# Changelog

## 0.4.0 — 2026-07-19

Pre-publish consolidation: correctness fixes at the fd layer plus a final API
finalization pass (breaking — 0.4.0 was never published).

**Correctness**

- `stop()` now restores the saved descriptors' original file-status flags.
  The mirror-to-original path sets `O_NONBLOCK` on the saved fds, and the
  flag lives on the open file *description* — shared with the fd 1/2 handed
  back on stop (and with the parent shell when the target is the tty) — so
  post-stop writes could `EAGAIN`, and the leak outlived the process.
- `maxLineBytes` is now enforced on newline-terminated lines too: a long line
  arriving within one read chunk previously bypassed the cap entirely. Runs
  are split byte-exactly into cap-sized pieces (an exactly-cap-sized line
  stays whole); the README's split guarantee is now unconditionally true.
- A reader-isolate death mid-session now restores fd 1/2 *immediately*
  (previously they stayed pointed at pipes nobody drained, and the app's next
  ~64 KiB of prints wedged the main isolate in a blocking `write()`).
  `pause()`/`resume()`/`startProcess`/`adopt` throw `StateError` on a
  degraded session; `readerError` + closed streams remain the signal.
- Saved-fd mirror overflow drops are now counted on the new dedicated
  `mirrorDroppedBytes` counter (they were silent; they are a separate channel
  from the line counters, which they deliberately do not pollute).
- `droppedLines`/`droppedBytes` now count exactly the lines missing from
  `history`: reader-side backpressure drops PLUS history-ring evictions
  (evictions were previously uncounted, making the documented totals wrong).
- `close()` is no longer retried on `EINTR` (on Linux/macOS the fd is
  deallocated regardless, so the retry was a double-close that could hit an
  unrelated reallocated fd).
- `stop()`'s drain-timeout path no longer closes fds a wedged-but-alive
  reader may still be blocked in `read()`/`poll()` on (deliberate bounded
  leak instead of fd-reuse byte theft), and the backstop
  `Isolate.kill(immediate)` is now issued only on that path — it can no
  longer race a healthy reader's cleanup.
- `startProcess()`/`adopt()` after `stop()` now throw `StateError` instead of
  silently discarding the child's output.
- A throwing `classify` callback no longer burns reader send credits (which
  permanently stalled the live feed after ~8 throws): the line is treated as
  unclassified and the first error is surfaced once on `readerError`.
- `open(2)` is bound through `VarArgs` like the other variadic syscalls.
- `StdioRedirect.stop()` releases the process-wide slot in a `finally`, so a
  (nearly impossible) restore failure can no longer wedge the package with
  no way to start a fresh session.

**Breaking API changes**

- Renamed the main class `StdioCapture` → `Stdio`, so the entry points read
  as `Stdio.capture` / `Stdio.start` / `Stdio.redirectToFile` (matching the
  package name).
- `Captured` is now `Captured<T>` with a `value` field: `Stdio.capture<T>()`
  returns the body's result alongside the transcript, and `stop()` returns
  `Future<Captured<void>>`. `Captured` also gained `droppedLines` /
  `droppedBytes` (lines missing from `lines`).
- `Stdio.capture()` accepts `historyLines` / `maxLineBytes` / `mirrorToFile`
  / `classify`, forwarded to `start()`.
- `startProcess()` returns `CapturedProcess` (the `process` plus a `drained`
  future that completes on full delivery); `adopt()` now returns
  `CapturedProcess` too (it was the bare drain future — ambiguous at the
  call site) and throws a clear `StateError` when the child's streams were
  already claimed (adopted twice / listened before adopt).
- Renamed `mirrorToSavedFds:` → `mirrorToOriginal:` (introduced unpublished
  after 0.3.0), with real documentation and, new in this release, drop
  accounting (`mirrorDroppedBytes`) and end-to-end tests.
- `terminal` is now typed `StdoutTerminalSink` — an `IOSink` with the
  terminal accessors *and* a concrete `Stdout` — and the redundant
  `terminalStdout` is gone (it was a second mutable-encoding handle to the
  same fd). `terminalStderr` (introduced unpublished after 0.3.0) stays, as
  the saved fd 2 counterpart. The abstract `TerminalSink` interface is gone
  too: it had no consumers and both implementations are final, so
  `FdTerminalSink` is now the documented base type (nullable-safe
  `columns`/`rows`; `StdoutTerminalSink` adds the throwing Stdout-contract
  `terminalColumns`/`terminalLines` view of the same data).
- `CapturedLine` gained `seq`, a monotonic per-session sequence number
  stamped as each line enters the transcript — the robust history→stream
  stitch across `await`s (the constructor now requires it).
- `CapturedLine.text` strips one trailing `\r` (CRLF output reads clean);
  `bytes` stays byte-exact. `StdoutTerminalSink.writeln` honors
  `lineTerminator` (payload `\n`s still pass through untranslated).
- `StdioException` moved to its own library and is now exported (the 0.4.0
  pre-release changelog wrongly called the non-export deliberate: callers
  could neither catch it by type nor read `readerError` usefully).
- New `Stdio.anyActive` static — advisory "is any capture/redirect holding
  fd 1/2" probe for coordination; the uncoordinated second `start()` still
  throws `StateError`.
- pubspec: `platforms: linux, macos` declared explicitly (POSIX-only).

**Docs**

- The README and library summary are general-purpose — capturing native and
  child output is the headline; the terminal handle is one use among several.
- Honest transcripts: `stop()`/`capture()` return the *retained* transcript
  (the last `historyLines` lines; see `droppedLines`) — the docs no longer
  claim everything is guaranteed present, and note that a throwing `capture()`
  body loses the transcript (use `start()`/`stop()` for post-mortems).
- Documented: main-isolate-only entry points, the double-start `StateError`
  on every entry point, `redirectToFile` moving BOTH descriptors, the
  FIFO-mirror caveat, `readerError` carrying the stringified isolate error,
  the gap-free history→subscribe recipe (and `seq` stitching), and
  the sink `flush`/`close` no-op semantics on the sink type itself.
- `dart run stdio:verify` is mentioned as the platform self-check.

## 0.3.0 — 2026-07-05

- `pause()` / `resume()` / `isPaused`: temporarily point fd 1/2 back at the
  real terminal without tearing the session down — the terminal-handoff
  primitive for TUIs (spawn `$EDITOR`/a pager with `inheritStdio` mid-session;
  the child inherits the real descriptors). Buffered writers are flushed at
  both edges so bytes land on the side of the boundary they were written on.
  `stop()` remains safe while paused.

## 0.2.0 — 2026-07-04

API finalization (breaking, pre-publish) + production-hardening.

**Renamed: `stdio_capture` → `stdio`** (import `package:stdio/stdio.dart`).
The scope is the process's stdio descriptors — capture, scoped capture,
reroute, and the saved-terminal handle. stdin is deliberately untouched (a
TUI keeps reading keys); fd-level stdin injection is a natural future
addition.

**API** — the surface now mirrors `Process.start`/`Process.run`:

- `collect()` → `capture()` (returns `Captured`, as before).
- `divertToFile()` → `redirectToFile()` (matches `StdioRedirect`).
- The combined feed is a real stream: `capture.listen(...)` → `capture.output`
  (`Stream<CapturedLine>`, composable like `stdout`/`stderr`).
- `stop()` now returns `Future<Captured>` — the same transcript `capture()`
  yields.
- `backlogLines:` → `historyLines:` (names what it bounds: `history`).
- `CapturedLine.rawBytes` → `bytes`; `CapturedLine` is now immutable
  (`source` is final — the classifier tags via copy).
- `startProcess` gained `runInShell`/`includeParentEnvironment` pass-throughs.
- `FdTerminalSink` is exported (it was the hidden supertype of
  `StdoutTerminalSink`).
- If the reader isolate dies mid-session the line streams now close (listeners
  get `onDone`) with the cause on `readerError`, instead of going silent.

**Hardening** (see the 0.1.x → 0.2.0 commit for the full story):

- Root-fixed a variadic-FFI ABI bug: `fcntl`/`ioctl` (and `open`) are variadic
  in C, and fixed-arity bindings pass the third arg in a register while
  arm64-macOS callees read the varargs stack — `F_SETFL` set random flags
  (O_NONBLOCK intermittently missing → blocking drains → data loss on fast
  stops) and `TIOCGWINSZ` never worked. Bound with `VarArgs`;
  `setNonBlocking` is verify-or-throw.
- `stop()` restores fd 2 from its own saved dup (it was restored from fd 1's,
  silently re-routing stderr whenever they differed).
- `capture()` restores the redirect even when the body throws.
- Reader lifecycle notifications share the data port (cross-port delivery has
  no ordering guarantee; a separate exit port could outrun queued batches).
- Mirror file opens (and fails) at `start()` instead of inside the reader.
- O(1) ring buffers; bounded, verified non-blocking end to end.
- Platform coverage verified: the full suite + fast-stop stress probe pass on
  macOS arm64 and in Linux arm64 + amd64 containers — all three varargs ABI
  conventions the `VarArgs` bindings must satisfy.
- `maxLineBytes` (default 64 KiB) bounds the in-progress line: a writer that
  never emits `\n` is delivered in cap-sized pieces instead of growing memory
  without bound (makes the "never OOMs" guarantee unconditional).
- README no longer implies the package installs signal handlers (it never
  did, deliberately): restore is `stop()`'s job — wire your signal handling
  to call it.

## 0.1.0 — 2026-07-04

Initial implementation: fd-level `dup2` capture of stdout/stderr with a
dedicated drain isolate (bounded backpressure, credit-based delivery,
self-pipe control), line assembly, history ring, durable mirror file,
subprocess tagging, classifier hook, scoped capture, file redirect, and the
saved-terminal render sinks (`TerminalSink`/`StdoutTerminalSink`).
