# VOICE-TICS — profile doc-voice models for repetitive editorial tics (#382)

Source finding: drawmeanelephant/filed.fyi#1061. The mild doc-voice pass
(SWE-2 via `devin acp`, filed #1057–#1060, 158 records) layers one winking
narrator over the archive. Every reply passes the guard; the problem only
shows across a batch, so nothing measured it.

## What landed

| Path | What |
|---|---|
| `knap-mcp/src/voicetics.zig` | `knap-mcp voice-tics`: model-free scorer over (before, after) pairs; after is a patched `.md` or a `doc-voice --report` JSON. Runs are paired with `voice.docWalk`. 6 tests, fixture from the issue's own diffs. |
| `knap-mcp/src/main.zig` | One CLI row, one help line, one test import. |
| `knap-mcp/eval/voice-tics/run.sh` | Sampling harness: corpus × provider profiles × prompt variants through `doc-voice --dry-run`, scored, one table. `mock` is the offline gate. |
| `knap-mcp/eval/voice-tics/pr.sh` | Scores filed PRs as shipped (merge base vs head, via `gh`). For batch review before merge. |
| `knap-mcp/eval/voice-tics/corpus.txt` | 6 pre-pass filed records (2 mascots, 2 lorelog, 2 reference; 79 runs), read from a local filed checkout at `ce44821f`. filed.fyi is all-rights-reserved, so its text is not vendored. |
| `knap-mcp/eval/voice-tics/variants/{deadpan,stress}/` | Prompt overlays (`mild.md`, `examples/mild.jsonl`) for A/B via `KNAP_PROMPTS_DIR`. |
| `knap-mcp/eval/voice-tics/fixture.{before,after}.md` | Scorer fixture + `--corpus local` records. |

## Metrics (per profile)

- **tic runs**: changed runs that gained a stock interjection (lexicon) or an
  *ironic italic*: an added one-word lowercase `*x*`/`**x**`/`==x==` over a
  word the run already had (`*helpfully*`, `*admired*`). Emphasis over a
  multi-word or capitalized term (`*freshness score*`) is counted in
  `emphasis_on_existing` but is not a tic.
- **lexicon /100**: added lexicon phrases per 100 changed runs. The lexicon
  (`default_lexicon`, ~60 phrases) is a seed; `--lexicon <file>` replaces it.
- **reworded**: the run's words are no longer a subsequence of the reply's
  (reordered or deleted, as in "…in its purest form").
- **repeat share / distinct**: share of added content words that belong to a
  term added in ≥ `--min-runs` (3) runs; distinct added words over all added.
  Both grow with sample size, so compare rows over the same corpus only.
- **dashes**: em/en dashes added.
- **density +** (`run.sh` only): mean `density_after - density_before` per
  record, from the reports. This is what the batches were run for (the 25.0
  policy band), so it's the cost side of any de-tic change.

## Production baseline: filed #1057–#1060 as shipped (`pr.sh 1057 1058 1059 1060`)

| batch | records | changed runs | tic runs | lexicon /100 | ironic italics | reworded | repeat share | top repeats |
|---|--:|--:|--:|--:|--:|--:|--:|---|
| #1057 | 8 | 87 | 70% | 47 | 35 | 63% | 30% | rather ×6, though ×6, quietly ×5, it turns out ×4 |
| #1058 | 85 | 1504 | 63% | 38 | 546 | 47% | 64% | rather ×94, quietly ×50, politely ×49, regrettably ×42 |
| #1059 | 57 | 781 | 58% | 40 | 225 | 47% | 56% | quietly ×46, rather ×45, regrettably ×29 |
| #1060 | 8 | 69 | 63% | 36 | 28 | 55% | 11% | remains ×5, rather ×4, somewhat ×4, of course ×3 |
| **all** | 158 | 2441 | **61%** | **39** | **834** | 48% | **70%** | rather ×149, quietly ×103, regrettably ×75, politely ×67, though ×67 |

The issue's hand count (regrettably 29, somewhat 15, of course 11, …) was
for #1059's added lines only; the scorer finds the same set plus `rather`
and `quietly`, which outnumber `regrettably` 2:1 and weren't in the review.

## Live sample: 6-record corpus, mild, 2026-10-29 (`run.sh`)

| profile | variant | model | changed | density + | tic runs | lexicon /100 | ironic italics | reworded | repeat share | top repeats |
|---|---|---|--:|--:|--:|--:|--:|--:|--:|---|
| devin-swe-2 | base | swe-2-high | 75 | +5.8 | 68% | 54 | 26 | 54% | 19% | quietly ×7, helpfully ×3, it seems ×3, politely ×3 |
| droid-spark-1.3 | base | muse-spark-1.3 | 75 | +7.1 | 81% | 45 | 32 | 48% | 32% | quietly ×9, politely ×7, predictably ×4, merely ×3 |
| devin-wonder | base | muse-wonder-1-0-high | 74 | +6.0 | 79% | 40 | 34 | 40% | 32% | regrettably ×7, helpfully ×3, predictably ×3 |
| droid-deepseek | base | deepseek-v4.1-flash | 75 | +7.2 | 70% | 18 | 43 | 61% | 3% | regrettably ×3 |
| droid-glm | base | glm-5.3-flash | 76 | +6.2 | 56% | 27 | 31 | 69% | 17% | quietly ×8, after all ×3, alas ×3, merely ×3 |
| devin-nemotron | base | nemotron-3-ultra-high | 71 | +5.5 | 39% | 18 | 16 | 59% | 4% | — |
| devin-swe-2 | deadpan | swe-2-high | 15 | +2.0 | 0% | 0 | 0 | 53% | 0% | — |
| droid-glm | deadpan | glm-5.3-flash | 35 | +3.9 | 2% | 0 | 1 | 60% | 0% | — |
| droid-spark-1.3 | deadpan | muse-spark-1.3 | 5 | +0.0 | 0% | 0 | 0 | — | 0% | — |
| devin-swe-2 | **stress** | swe-2-high | 75 | **+8.7** | **17%** | **0** | 13 | **0%** | 0% | — |
| droid-spark-1.3 | **stress** | muse-spark-1.3 | 73 | **+8.9** | **12%** | **0** | 9 | 4% | 0% | — |

Not sampled: `codex`, `gemini` and `opencode-spark-1.3` failed every call on
account errors (codex-acp "Internal error", gemini 403, opencode
"Insufficient account funds"). The harness now fails such a profile instead of
tabling zeros. `droid-mistral` runs ~1 min per call and was still going;
`droid-glm@stress` was incomplete at writing. `droid-spark-1.3` is a private
profile (`knap_droid muse-spark-1.3 'Muse Spark 1.3' low`) until
`scripts/providers.sh` gets the arm.

## Findings

1. **The prompt seeds the persona.** `prompts/voice/examples/mild.jsonl`
   outputs contain `regrettably` twice, plus `a pleasant`, `less pleasantly`,
   `*reserved*` and `respectable`. `mild.md` asks for "one `*italic*` … for
   the raised eyebrow" and "at most one touch of wit per value". Every
   paragraph is a separate call, so every paragraph gets its own wink.
2. **It's every model, and they converge.** All six live models tic in
   39–81% of rewrites, with the same word family (quietly, regrettably,
   politely, helpfully, merely, rather). They even pick the same joke word:
   five of six italicized `*admired*` in the same LLG-0316 sentence. Swapping
   models doesn't fix it; Nemotron is the least tic-prone and DeepSeek uses
   the fewest stock phrases but the most ironic italics.
3. **Under mild, the wink is the density.** mild allows only `*italic*`, so
   ironic italics are the cheapest density points. Telling models to stop
   (`deadpan`) kills the tics and most of the lift (SWE-2 +5.8 → +2.0;
   Spark 1.3 rewrites 5 of 79 runs).
4. **Redirecting the emphasis keeps the lift.** `stress` bans the narrator but
   makes emphasis on the load-bearing term (a name, rule, number, status) the
   main tool. On two models: 0 stock phrases, tic runs 68–81% → 12–17%,
   rewording 48–54% → 0–4%, and density **higher** than base (+8.7/+8.9 vs
   +5.8/+7.1).

## Gates

- `make test`: 305/305.
- `KNAP_MCP_HOME=$(mktemp -d) make eval`: converged 12/22 and 120/167 (unchanged).
- `knap-mcp/eval/voice-tics/run.sh --corpus local mock`: pass (mock italicizes
  one existing word per run; the gate asserts exactly that).
- `zig fmt --check src`, `shellcheck -x` on both scripts: clean.
- Both overlays pass `prompts/voice/check.sh`'s guard checks; the only
  failures are the deliberate "output equals input" examples (`deadpan` 6,
  `stress` 2), an authoring rule, not a runtime one.

## For other lanes / follow-ups

- **VOICE** (`prompts/voice/`): adopt `variants/stress` as mild, regenerate
  `testdata/system.mild.txt`; check.sh's "output equals input" rule needs the
  two unchanged examples reworked or the rule scoped to rewritable roles.
- **FILED-VOICE** (`voice.zig` docGuard): a hard reject for replies that add a
  lexicon phrase would stop the narrator regardless of prompt or model.
  `voicetics.default_lexicon` is `pub` for that.
- **LIVE** (`scripts/providers.sh`): add `droid-spark-1.3`. Droid 0.251's
  `--help` still lists only `muse-spark-1.2`, but `muse-spark-1.3` works.
- **filed**: run `pr.sh <n>` on every voice batch before merge. The #1061
  rulings (strip #1059/#1060 tic hunks, retro sweep #1057/#1058) are human
  calls; the per-record numbers are in `pr.sh`'s `profile.json` outputs.
