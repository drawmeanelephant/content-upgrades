# AB: backend/engine audit fixes (issues #43, #44, #49, #50)

Lane AB. Owner files: `src/backend.zig`, `src/engine.zig`, `src/ctx.zig`,
this note. Issues #43 (timeouts), #44 (key on disk), #49 (mock patch
fidelity), #50 (live HTTP handling).

## What landed

### #43 — subprocess timeouts

- `engine.zig`: `render` and `lint` share a new `runEngine` helper that
  passes a hard `.deadline` to `std.process.run` (Zig 0.17's
  `RunOptions.timeout`; on expiry `run` kills the child and returns
  `error.Timeout`, which surfaces as a normal tool error
  `engine '<path>' timed out after Ns`). Tunable via
  `KNAP_ENGINE_TIMEOUT` seconds, default 60, `0` disables.
- `backend.zig`: the curl argv now carries `-m $KNAP_CURL_TIMEOUT`
  (default 60) and `--connect-timeout $KNAP_CURL_CONNECT_TIMEOUT`
  (default 10). Because curl now needs stdin for `-K -`, the call went
  from `std.process.run` to a local `runCurl` helper (spawn + stdin write
  + `Io.File.MultiReader` + absolute deadline of `KNAP_CURL_TIMEOUT+15s`
  as a backstop in case curl itself wedges). `error.Timeout` →
  `ctx.fail("curl timed out; the backend is unreachable or hung")`.
- `ctx.zig`: shared helpers `envSecs(name, default)` and
  `deadline(secs) -> Io.Timeout` (`.none` for 0, else `.deadline` on the
  `awake` clock — a whole-process cap, not per-read idle).
- `boris.zig` deliberately untouched — another lane owns its timeout.

### #44 — MODEL_API_KEY never touches disk

- The `scratch-*.header` file is gone. The `Authorization: Bearer <key>`
  header now travels as a `-K -` curl config stream on the child's stdin
  (`header = "Authorization: Bearer ..."`). The JSON body still goes
  through a 0600 scratch file (no secret, prompt only) with the existing
  defer-delete.
- `chatCompletion` calls `warnProjectTreeStore` once per process
  (`Ctx.store_warned` latch): when `store_dir` is relative — i.e.
  `KNAP_MCP_HOME` unset or a relative path — a loud stderr warning tells
  the user to set `KNAP_MCP_HOME` to a private dir. Warn-not-refuse: the
  key itself never reaches disk anymore; what lands in the project tree
  is non-secret scratch data.

### #49 — positional mock patches

- `stripUnknownFilter` now maps `diag.line`/`diag.col` through `offsetOf`
  and only strips `| <name>` inside the `{{ }}` tag that is still open at
  that position (bounded by the tag's `}}`). An earlier same-named
  filter in another tag survives.
- The `unclosed if/for block` rules append a closer only when
  `hasUnclosedBlock` finds an actually-unmatched `{% if %}`/`{% for %}`
  opener in the region (keyword-boundary scan, so `{% elseif %}` and
  substrings don't count). A bare detail-string match on a region with
  no unmatched opener now returns null.

### #50 — live HTTP fidelity

- `-f` → `--fail-with-body` plus `-w '\n%{http_code}'` (requires curl
  >= 7.76; macOS ships 8.x). The trailing status line is split back off
  stdout; HTTP >= 400 errors now report `backend http <status>: <provider
  body>` instead of `backend http 22`.
- Provider/curl output embedded in tool errors is truncated to 300 bytes
  via `brief()`, cut on a codepoint boundary; collection caps are 8 MiB
  stdout / 64 KiB stderr.
- Empty `MODEL_API_KEY` now fails with `needs MODEL_API_KEY` instead of
  sending `Bearer ` and surfacing a 401.
- `remotePatch` runs `sanitizePatch` on model output: trims, strips one
  surrounding code fence, rejects empty output, residual fences, and
  echoed prompt text; restores the region's trailing newline when the
  model dropped it.

## Interface notes for other lanes

- New env vars (not yet in `main.zig` usage text — the CLI table is a
  shared file, so the merge captain may want them documented there):
  `KNAP_ENGINE_TIMEOUT` (engine subprocess seconds, 60, 0=off),
  `KNAP_CURL_TIMEOUT` (60), `KNAP_CURL_CONNECT_TIMEOUT` (10).
- `main.zig` `backends` still treats an empty `MODEL_API_KEY` as "set" —
  cosmetic only; `complete()` rejects empty keys with the clear error.
- `Ctx` gained `store_warned: bool = false` (warning latch) — test
  `Ctx{...}` literals keep working via the default.
- The repair loop now sees `null` from the mock for unclosed-block diags
  whose region lacks an unmatched opener; that reads as non-convergence,
  which is the intended behavior per #49.

## Gates

- `make test` — green (includes new tests: positional strip, unmatched-
  opener check, sanitizePatch, brief UTF-8 cut).
- `KNAP_MCP_HOME=$(mktemp -d) make eval` — green; table output
  byte-identical to origin/main modulo the report doc-id line
  (seeds.json 12/22 converged, seeds.2nap.json 120/167, same mean iters
  and exact counts).
- Live path (`MODEL_API_KEY`) untestable here; verified by review +
  `curl -K -` parsing checked on the installed curl 8.7.1.
