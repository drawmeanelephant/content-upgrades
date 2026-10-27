# Track AH: audit-hygiene batch

Fixes for the Oct 26 audit: #48 (verify_citation state leak), #51 (ten
handler-level arg-validation and JSON-hygiene items), #46 store side
(artifact retention + scratch cleanup), #43 boris side only (subprocess
timeout). #57 item 2 rides along because the fix is the same code path.

## What landed

**#48 — `knap_verify_citation` no longer mutates shared state.**
`tools/verify_citation.zig` copies `ctx` per call and sets `backend_kind`
on the copy; `verifier.checkCitation` reads the copy. A `backend` arg now
applies to that call only. (verifier.zig untouched — its signature reads
the kind off the ctx it is handed, which is the sanctioned seam.)

**#51 — ten small fixes.**
1. `tools/repair.zig`: unknown `backend` now fails like voice/ratchet
   instead of silently falling back to `ctx.backend_kind`.
2. `tools/common.zig` `requireData`: rejects non-object `data` up front
   (`"data":"x"` -> `"data must be a JSON object"`) instead of staging a
   bare string for the engine to choke on. **This also covers #57 item
   2:** `mcp.zig` now parses requests with `.parse_numbers = false`, so
   `data` arrives as `.number_string` lexemes and re-stringifies
   byte-for-byte — `{"year":1.50}` stays `1.50` through `knap_voice`
   (verified end to end: the tool result's `data` echoes `1.50`).
   `toolsCall` re-parses `.number_string` on every *other* argument into
   `.integer`/`.float`, so scalar args (ratchet's `max_iterations`/
   `epsilon`, boris_ask's `limit`) behave exactly as before. Residual:
   the CLI path's `readData` in `src/main.zig` (not mine) still parses
   with default options, so `--data` files re-encode `1.50` -> `1.5` —
   same one-line fix belongs to main.zig's lane.
3. `tools/verify_citation.zig` schema: `oneOf` -> `anyOf`.
4. `knap_lint` clean-detection now keys off the k4o exit code, not a
   "clean" substring. **CROSS-LANE NOTE — `src/engine.zig` (minimal,
   surgical):** `engine.lint`'s return type changed `Outcome` ->
   `LintResult{ outcome, exit_code }`; `LintResult` is the only addition.
   Its sole caller was `tools/lint.zig` (mine).
5. `tools/templates.zig`: `shapes/<id>.json` is parsed and re-stringified
   instead of inlined raw — a malformed shape file is skipped rather than
   corrupting the `knap_templates` result.
6. `tools/structure_hash.zig`: `strict` must be a real boolean;
   `"strict":"yes"` or `strict:1` is a tool error.
7. `mcp.zig` `resources/list`: template ids and doc_ids go through
   `std.json.Stringify.value` — a filename containing a quote can no
   longer break the payload.
8. `boris.zig` `mapReport`: report.json line/column values clamp to
   `[0, maxInt(u32)]` via `clampU32` instead of panicking in `@intCast`.
9. `boris.zig` `mapReport`: staged->doc column mapping now subtracts
   per-line rewrite drift. `Link` gained `staged_len` (bytes the link
   occupies after rewriting); a body diagnostic's doc column is its
   staged column minus the net drift of every link ending left of it on
   the same staged line. Verified: a diag after `[[T]]`->`[[slug|T]]`
   (+20 bytes) maps back to the correct doc column.
10. `store.scratchFile` names are `scratch-<pid>-<ns>-<counter>.<ext>` —
    the pid ends cross-process name collisions on a shared
    `KNAP_MCP_HOME`.

**#46 — store side.** `store.put` prunes the `doc-*` FIFO to the newest
`KNAP_STORE_MAX_ARTIFACTS` (default 256, 0 disables) after every write;
foreign files in the artifacts dir are never counted or evicted. Scratch
cleanup: `mcp.serve` sweeps this process's `scratch-<pid>-*` files after
every request, and my handlers defer-delete what they stage
(`tools/repair.zig` data file, `tools/lint.zig` template_text file;
boris.zig already `deleteTree`d its staging dir). `stageData` callers in
other lanes' files (`tools/render.zig`, `tools/validate.zig`) and the
`src/repair.zig`/`ratchet.zig`/`eval.zig` writers are covered by the
server sweep but still leak one file per CLI invocation — their lanes'.

**#43 — boris site only.** `boris.check`'s `boris validate` spawn passes
`.timeout` to `std.process.run`, bounded by `KNAP_BORIS_TIMEOUT` seconds
(default 60, 0 disables) via `ctx.envSecs`/`ctx.deadline` — the helpers
lane AB added for `KNAP_ENGINE_TIMEOUT`. On expiry `run` kills the child
and the call returns a normal tool error — verified with a `sleep 300`
stand-in: fails at the deadline, server unblocked. engine.zig's
subprocess path and backend.zig's curl argv are another lane's.

## Gates

- `zig build test` / `make test`: green (114 tests, incl. new coverage in
  store, common, repair, structure_hash, verify_citation, boris).
- `KNAP_MCP_HOME=$(mktemp -d) make eval`: green — 120/167 converged,
  controls 2/2 clean, same table as main.
- `knap-mcp/eval/boris/run.sh`: green — 25/25 ask queries identical,
  14/14 labeled claims right.

## Repros verified

`strict:"yes"` and `strict:1` -> `"strict must be a boolean"`;
`"data":"x"` -> `"data must be a JSON object"`; `{"year":1.50}` survives
`knap_voice` verbatim; scratch names carry the pid and are deleted;
4 renders under `KNAP_STORE_MAX_ARTIFACTS=2` leave 2 artifacts;
report.json `line:99999999999` clamps instead of aborting; hung boris
dies at `KNAP_BORIS_TIMEOUT`.
