# EVAL: slice-economy counters (issue #80)

Lane EVAL. Owner files: counter fields in `knap-mcp/src/ctx.zig`, the
counting lines in `backend.zig` / `ratchet.zig` / `voice.zig`, the summary
printers in `eval.zig` / `ratchet.zig`, this note.

## What landed

- **`Ctx` counters**: `calls`, `slice_bytes_total`, `slice_bytes_max`,
  `prefix_bytes`, plus `countCall(prefix, slice)` and `meanSlice()`. The
  prefix is recorded, not summed — it's the cache-stable system prompt.
- **Counting at the choke points.** `backend.complete` counts every live
  call (repair, enrich, voice, verify). The mock paths count the slice they
  would have sent: `repairPatch` builds the same user message a live call
  carries (`repairUser`, now shared with `remotePatch`), ratchet's `ask`
  builds `buildSlice` before dispatching to mock, and `voiceData` counts
  `userMessage` per slot — with the real assembled system prefix when the
  prompts dir has it (eval/voice's private `KNAP_PROMPTS_DIR` controls ship
  only mock lines, so the prefix falls back to 0 there).
- **Summary lines.** `knap-mcp eval` and `knap-mcp ratchet-eval` print
  `calls: N  mean slice: X B  max: Y B  prefix: Z B` in the summary block.
  `knap-mcp voice` prints the same line on stderr at the end of a run
  (stdout stays the JSON contract). The line is skipped under `zig test`:
  stray stderr from test-covered code trips the test runner's
  `--listen=-` protocol (deterministic on a fresh cache, silent pass on
  reruns — looked flaky).

## Recorded mock numbers

- `eval --corpus eval/seeds.json`: `calls: 25  mean slice: 475 B  max: 2057 B  prefix: 331 B`
- `eval --corpus eval/seeds.2nap.json`: `calls: 193  mean slice: 149 B  max: 232 B  prefix: 331 B`
- `ratchet-eval` (eval/ratchet.json): `calls: 70  mean slice: 815 B  max: 1435 B  prefix: 372 B`
- `voice verdict --backend mock`: `calls: 5  mean slice: 144 B  max: 286 B`; prefix 5752 B (mild), 5803 B (spicy), 6457 B (feral).

## Left for another lane

`make voice-eval`'s printed summary comes from `knap-mcp/eval/voice/run.sh`,
which is outside this lane's file list — the script captures each `voice`
call's stderr into `$work/voice.err`, so the numbers line doesn't reach its
stdout summary. A one-line echo/`note` in run.sh (or moving aggregation into
a Zig `voice-eval` command) would surface it.
