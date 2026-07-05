# Changelog

## 0.2.0 — 2026-07-04

API finalization (breaking, pre-publish) + production-hardening.

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

## 0.1.0 — 2026-07-04

Initial implementation: fd-level `dup2` capture of stdout/stderr with a
dedicated drain isolate (bounded backpressure, credit-based delivery,
self-pipe control), line assembly, history ring, durable mirror file,
subprocess tagging, classifier hook, scoped capture, file redirect, and the
saved-terminal render sinks (`TerminalSink`/`StdoutTerminalSink`).
