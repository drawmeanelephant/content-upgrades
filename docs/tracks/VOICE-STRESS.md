# VOICE-STRESS — adopt the measured 'stress' mild tone (#384)

Source finding: drawmeanelephant/filed.fyi#1061, measured in
`docs/tracks/VOICE-TICS.md` (#382, PR #383). The shipped mild prompt seeded
a stock narrator (regrettably, quietly, politely, ironic `*italics*`) on
61% of rewritten paragraphs. The `variants/stress/` overlay — no narrator,
emphasis on the load-bearing term — took stock phrases to 0 and tic runs
from 68–81% to 12–17% while *raising* density gain on both sampled models.

## What landed

`eval/voice-tics/variants/stress/` is now the shipped mild tone:

| Path | What |
|---|---|
| `knap-mcp/prompts/voice/mild.md` | Replaced with the stress overlay: archivist persona, no asides/interjections/hedges, `*italic*` marks the one term a skimmer must not miss (never irony), wording kept, return-unchanged allowed, 0.8–1.0× length. |
| `knap-mcp/prompts/voice/examples/mild.jsonl` | The overlay's 10 rewritten examples (emphasis, no narrator); the `title` and `subtitle` lines kept as shipped because the overlay left them unchanged and `check.sh` fails output-equals-input examples. |
| `knap-mcp/prompts/voice/testdata/system.mild.txt` | Regenerated via `assemble.sh system mild`. |

`spicy.md`, `feral.md`, their examples, `system.md` and `mock/` untouched.

## Live check: adopted mild, 6-record filed corpus, 2026-10-29

`KNAP_FILED_DIR=~/dev/filed.fyi knap-mcp/eval/voice-tics/run.sh --out <dir> devin-swe-2`
(variant `base` = shipped prompts, now the stress tone):

| profile | variant | model | corpus | runs | changed | rejected | density + | tic runs | lexicon /100 | ironic italics | dashes | reworded | repeat share | distinct | top repeats |
|---|---|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|
| devin-swe-2 | base | swe-2-high | filed | 79 | 76 | 1 | 8.8 | 10% | 0 | 8 | 0 | 1% | 0% | 100% | — |

Done-when thresholds: lexicon /100 ≤ 5, tic runs ≤ 25%, density + ≥ 5.8 —
0, 10%, +8.8. The remaining 8 tic runs are ironic one-word italics
(`*current*`-type), not stock interjections; density is up vs the old
mild's +5.8 on the same corpus and profile.

## Gates

- `make test`: 305/305.
- `KNAP_MCP_HOME=$(mktemp -d) make eval`: converged 120/167, mean iters
  1.19, exact 66/115, controls 2/2 clean (unchanged).
- `make voice-eval`: pass (15 template × tone mock runs match the jq
  reference).
- `sh knap-mcp/prompts/voice/check.sh`: 36 examples, 240 mock replies,
  75/75 selftest breaks caught, 0 warnings, 0 failures.

## For other lanes

- **FILED-VOICE** (`voice.zig` docGuard): the prompt now bans the
  narrator, but a hard reject on added lexicon phrases would still
  enforce it regardless of prompt or model; `voicetics.default_lexicon`
  is `pub`.
- **VOICE-TICS**: `variants/stress/` in the eval dir is now identical to
  the shipped mild (modulo the two kept examples). Future A/Bs should
  diff against a `pre-stress` overlay or git history, not `stress`.
