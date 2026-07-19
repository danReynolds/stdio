# stdio

FD-level capture/redirection of stdout/stderr for Dart: `dup2` moves fd 1/2
themselves, catching the native/FFI and child-process writes that zones and
`IOOverrides` can't see (Dart's wurlitzer). POSIX only — Linux + macOS. Sole
runtime dep: `package:ffi`. Primary consumer: `../dune_cli` (path dep) uses
capture + `pause()`/`resume()` for TUI alt-screen purity — API breaks ripple
there immediately.

## Commands
- `dart pub get` · `dart test` · `dart analyze` (keep at zero issues).
- Tests are POSIX-only; the real e2e suite is `bin/verify.dart`, which
  `dart test` runs as a subprocess (in-process capture would grab the test
  runner's own fds). Direct: `dart run bin/verify.dart` — exit 0, "ALL
  CHECKS PASSED" on stderr (on stdout would mean fd 2 was mis-restored).

## Architecture notes
- `lib/src/stdio_base.dart` (API/lifecycle) + `posix.dart` (all FFI): `dup()`
  saves the terminal fds, two `pipe()`s are `dup2`'d over fd 1/2; the saved
  fd backs `terminal`/`terminalStderr` so a TUI renders during capture.
  Process-global: a second live `start()`/`capture()` throws `StateError`.
- The reader isolate (`reader.dart`) blocks in `poll()` — no event loop —
  and owns all backpressure: continuous drain (writers never block),
  drop-oldest history, 64 KiB line cap. Main→reader control is a self-pipe
  (byte 1 = credit, 0 = stop), not a SendPort.
- `stop()` restores fd 1/2 FIRST, then EOFs → drains → joins the reader.
  That order loses no in-flight bytes and no writer sees EPIPE. Teardown is
  memoized (`_finishing`): concurrent/repeated `stop()` is safe.
- `pause()`/`resume()` re-check liveness (`_checkLive`) after every await —
  a concurrent `stop()` during the flush gap closes the saved fds, and a
  late `dup2` would hit closed/reused descriptors (Jul 5 hardening).
- `open`/`fcntl`/`ioctl` are C-variadic: bind only via `dart:ffi` `VarArgs`.
  Fixed-arity bindings silently corrupt the third argument on arm64 macOS.

## Conventions & quality bar
- Concurrency/fd-lifecycle changes need a matching check in `bin/verify.dart`
  — house style is stress/race coverage (40k-line storm with the main isolate
  blocked, pause-window OS assertions, fd-restore regression). Never add
  tests that touch fd 1/2 inside the test-runner process.
- README "Semantics & guarantees" is the behavioral contract — update it in
  the same change as the behavior. Log releases in CHANGELOG.md.

## Pointers
- README "Design" — mechanism rationale, incl. the variadic-FFI war story.
- DOSSIER.md — Phase 2 (not yet written).
