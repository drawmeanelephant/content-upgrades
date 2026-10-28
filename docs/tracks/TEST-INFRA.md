# TEST-INFRA

Notes from the `make test` flake hunt (issue #240).

## The flake

Three identical sightings — PR #238 (MD-RN, seed 0x97b902f3), PR #239
(MD-RB), and a local `make test` repro (seed 0xb78ed112) — all on
fresh worktrees, all on the first cold-cache run:

```
test
+- run test w
knap-mcp: KNAP_BACKEND 'bogus' is not a backend kind (mock|spark|wonder|baseten|acp|compat)
knap-mcp: KNAP_BACKEND 'MOCK' is not a backend kind (mock|spark|wonder|baseten|acp|compat)
failed command: ./.zig-cache/o/<hash>/test --cache-dir=./.zig-cache --seed=0x<seed> --listen=-
```

No `error:` line, no test name, no Build Summary. The two stderr lines
are the *only* stderr any passing test produces (from ctx.zig's
KNAP_BACKEND case at ~test 53/209), so their being last only means the
binary died at or after that point — it does not implicate the env test.

## Why it's not a test bug

`zig build test` drives the binary with `--listen=-`: each test's start
and result is an IPC message, so the runner attributes every mid-test
death (`'<name>' terminated with signal X`, `'<name>' failed: ...`).
The only outputs that carry no attribution are:

- a propagated non-attributed error in `waitZigTest` (e.g. a transient
  `ConcurrencyUnavailable`/`ReadFailed`/`Canceled` on the runner's own
  io — all load-correlated), or
- the binary dying *between* tests (in per-test
  `testing.io_instance` init/deinit or the `serveTestResults` write) —
  still reported as `test process unexpectedly <term>`.

The bare `failed command` rules out a normal failure, a named crash,
and a named timeout; it is the signature of the IPC/runner layer itself
flaking under cold-run load.

Repro statistics: 1 failure on the first `make test` (cold cache), then
~200 consecutive passes — 120 standalone binary runs under 8-way
parallelism with random seeds, 26 with the failing seed, 40 warm
`zig build test` runs. The seed only changes test order; the death was
between messages, not inside a test.

## Fix

`knap-mcp/build.zig` sets `run_unit.stdio = .inherit` so `zig build
test` spawns the binary in terminal mode instead of through the
test-server channel. The channel (and its entire failure class) is
gone, and a future mid-binary death now names the last completed test
instead of producing an unattributed `failed command`.

## Still open (other lanes)

- `density.zig` `test "scoring every fixture takes under 50ms"` is a
  wall-clock assertion — the one remaining real timing flake in the
  suite. density.zig is owned by an open milestone-6 lane; flagged in
  the issue rather than edited here.
- `backend.zig` compat test spawns real `curl` against `127.0.0.1:1`;
  every failure mode still lands as `error.ToolFailed`, so it is
  robust, but it is a real network/process dependency.
