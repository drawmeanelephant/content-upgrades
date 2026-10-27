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

## Found while wiring: ratchet-eval is red on main TODAY

The issue's premise ("both pass on main today, 2026-10-26") is stale for
`ratchet-eval` — `plateau-dilution` fails deterministically:

```
| plateau-dilution | 0.3 | 43.6 | 43.3 | 44.1 | 4 | 15 | 4 | 4 | ... | ceiling | FAIL: stop ceiling, want plateau |
```

Bisected with identical cached engines (k4o `aeba163`, dogbed `d96b125`):

- `1cf992d` (#71, scorer density/1): PASS — 7/9 slots, 54.4 vs ceiling 56.5 → `plateau`
- `2051311` (dogbed pin → d96b125): PASS, identical
- `172fd74` (#72, density/2): FAIL — 4/9 slots, 43.6 vs ceiling 44.1 → `ceiling`

density/2's word-count saturation means any ~300-word fill still gains ≥
eps (swapping the `box` wall for pure filler changed nothing: 4 accepts,
43.6), so this scenario structurally converges to `ceiling` before
candidates exhaust. `plateau-dilution` is the only case covering
`stop: plateau`; the fix is corpus/scorer judgment, out of this lane's
files. Filed as #149.

This PR's CI will show `Ratchet eval (mock)` red until that lands — the
gate doing its job on a pre-existing regression, not breakage from this
change.
