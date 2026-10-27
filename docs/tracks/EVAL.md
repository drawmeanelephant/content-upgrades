# EVAL: eval corpora, fixtures, and expectations

## Issue #114 — plateau-dilution (landed)

`plateau-dilution` stopped `ceiling` under density/2 because the scorer's
new `min(1, words/200)` positive-credit scale changed what the stub climb
sees: `stubCeiling` climbs with short stub values, so the fixture rendered
under the word floor and the ceiling collapsed to 44.1 (density/1: 56.5).
The 167-word `box` mock reply then pushed the real run's length scale to
full credit and the run crossed the stub ceiling after only 4 accepts.

Fix: `eval/ratchet/ladder.data.json` `intro` is now ~200 words of plain
prose. Every render — stub climb included — sits above the floor, so the
ceiling is 54.8 and the diluted run stalls at 45.6 with every remaining
probe below eps: a genuine `plateau`, not a re-labeled `ceiling`.

**Load-bearing:** keep `intro` at ≥ ~200 words (the scorer floor is
`min_words = 200`). Shortening it drops both ladder cases (`budget-burn`
shares the data file) back under the word floor and re-breaks this case.
The `intro` is prose only, so it adds no apparatus to the start state.

## Issue #80 — slice-economy counters (#121)


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

### Recorded mock numbers

- `eval --corpus eval/seeds.json`: `calls: 25  mean slice: 475 B  max: 2057 B  prefix: 331 B`
- `eval --corpus eval/seeds.2nap.json`: `calls: 193  mean slice: 149 B  max: 232 B  prefix: 331 B`
- `ratchet-eval` (eval/ratchet.json): `calls: 70  mean slice: 815 B  max: 1435 B  prefix: 372 B`
- `voice verdict --backend mock`: `calls: 5  mean slice: 144 B  max: 286 B`; prefix 5752 B (mild), 5803 B (spicy), 6457 B (feral).

### Left for another lane

`make voice-eval`'s printed summary comes from `knap-mcp/eval/voice/run.sh`,
which is outside this lane's file list — the script captures each `voice`
call's stderr into `$work/voice.err`, so the numbers line doesn't reach its
stdout summary. A one-line echo/`note` in run.sh (or moving aggregation into
a Zig `voice-eval` command) would surface it.
