# CI3: gate ratchet-eval and voice-eval in make and CI

Issue #148. Wiring only — no `knap-mcp/src` changes, so mock `make eval`
output is byte-identical before/after.

## What landed

- `Makefile`: new `ratchet-eval` target (`cd knap-mcp && zig-out/bin/knap-mcp
  ratchet-eval`, default corpus `eval/ratchet.json`, mock backend), added to
  `.PHONY`.
- `.github/workflows/ci.yml`, job `build-test-eval`: two new steps after
  "Eval (mock convergence)":
  - `Ratchet eval (mock)`: `KNAP_MCP_HOME=$(mktemp -d) KNAP_ENGINES_DIR="$HOME/.cache/knap-engines" make ratchet-eval`
  - `Voice eval (mock)`: same env, `make voice-eval` (needs `jq`, present on
    `ubuntu-latest`).

## Wall time

Local (M-series MacBook, engines cached, binary prebuilt):

- `make ratchet-eval`: ~2.1 s (13 cases, ~350 ms/case probe cost)
- `make voice-eval`: ~1.4 s (12 template×tone runs + negative/guard controls)

Both far under the one-minute budget; actual runner times are in the PR's
`build-test-eval` step timings.

## Exit-code proofs (the gates really gate)

**ratchet-eval** — flipped one expect in a temp corpus copy
(`eval/ratchet.broken.tmp.json`, `release-notes-min` `min_gain` → 999),
uncommitted and deleted after:

```sh
zig-out/bin/knap-mcp ratchet-eval --corpus eval/ratchet.broken.tmp.json
# | release-notes-min | ... | FAIL: gain 32.1 < 999.0 |
# FAIL: a case missed its expectations
# exit code: 1   (ratchet.zig returns @intFromBool(failed))
```

**voice-eval** — corrupted the jq reference in place
(`eval/voice/apply-mock.jq`: `$m.output` → `$m.output + " CORRUPT"`), then
restored with `git checkout`:

```sh
make voice-eval
# voice-eval: FAIL: knap-mcp voice verdict --tone mild differs from the jq reference:
# ... (all 12 runs)
# make: *** [voice-eval] Error 1   → make exit 2, run.sh exit 1
```

Note: corrupting `prompts/voice/mock/*.jsonl` does NOT fail the eval — the
mock feeds both `knap-mcp voice --backend mock` and the jq reference
equally, so the two sides still match. The comparison surface is
`apply-mock.jq` (reference transform) plus the render/hash/negative-control
checks computed live.

## Correction: ratchet-eval is green on main

An earlier draft of this note claimed `plateau-dilution` was red on main —
that measurement was taken on a stale checkout (a local `main` several
commits behind origin, still on the 13-case corpus). On the current
20-case corpus the case passes:

```
| plateau-dilution | 8.0 | 45.6 | 37.6 | 54.8 | 6 | 15 | 6 | 6 | ... | plateau | ok |
all expectations met   (20 runs, calls: 84, mean slice 828 B)
```

The stale-tree failure was still real history worth recording: between
`172fd74` (#72, density/2 — whose commit message claimed "ratchet-eval
passes unchanged") and the corpus growth in `b609a06`/`d0363af` (#117/#125
footnote + verdict/apparatus ratchet slots, which raised the ladder's stub
ceiling 44.1 → 54.8), `plateau-dilution` genuinely could not plateau —
every ~300-word fill gained ≥ eps under density/2's word-count saturation,
so the run converged to `ceiling` before candidates exhausted. This gate
exists to catch exactly that drift window; it just arrived a few days late.
