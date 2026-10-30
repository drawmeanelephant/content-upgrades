# VOICE-DEDUP — no repeated additions across a doc-voice pass (#390)

Follow-up to VOICE-TICS (#382, filed.fyi#1061). The narrator guard (#388)
and the stress tone (#389) act per reply; `docGuard` judges one
(before, after) pair, so nothing could see the actual complaint — the
same added word turning up again and again across a batch (rather ×149
over 2441 changed runs). This lane makes repetition enforceable.

## What landed

| Path | What |
|---|---|
| `knap-mcp/src/voicetics.zig` | Factored `score`'s added-word multiset into `pub fn addedCounts`; new `pub fn addedContent` (sorted, de-duplicated non-stopword words `after` adds over `before`), `pub fn isStop`, `pub fn strLess`. `Counts` is now `pub`. Scorer semantics unchanged. |
| `knap-mcp/src/voice.zig` | `pub const Seen` (lowercased term → run index; 0 = ledger-loaded). `DocOptions.seen`: when set, the user message lists already-added terms, a reply re-adding one is retried once with the reuse called out, then rejected (`repeats 'x' added at run N` / `repeats 'x' from an earlier record`). Accepted replies register their additions. `voiceRun` gained the retry loop — still one call per run unless a seen-hit fires. |
| `knap-mcp/src/tools/doc_voice.zig` | The pass always dedups within a record. `--ledger <file>` (CLI) / `ledger` (MCP): one term per line, loaded into `seen` before the pass, rewritten sorted + deduplicated whenever a rewrite was accepted — terms the pass used are spent even if the doc fails publish-check (the eval harness's `frozen` staging fails `ok` on every change, so gating on `ok` would starve the ledger). `--ledger` into a `content/` dir is refused like `--out`. Report gains `added_terms`. |
| `knap-mcp/eval/voice-tics/run.sh` | `--ledger` shares one ledger per profile@variant dir across the corpus. |
| `knap-mcp/prompts/voice/{mild,spicy,feral}.md` + `testdata/system.*.txt` | One contract line each: terms already added in this pass are spent. Goldens regenerated via `assemble.sh`. |

## Semantics

- A "term" is a content word (the scorer's non-stopword set) the reply
  adds occurrence-wise over its input. Emphasis on an existing word adds
  nothing, so mock's `*x*` runs are untouched and the offline gate is
  unchanged. Emphasis-term dedup (the "all six models italicize
  `*admired*`" convergence) is deliberately out of scope — watch the
  `emphasis` tally in the live table.
- Matching is case-insensitive at the seen boundary; the ledger stores
  lowercase.
- Two strikes, then out: first reuse retries with "Your previous reply
  re-used 'x' — rewrite without it"; a second hit (same or different
  term) rejects and the run keeps its original. Canned replies can't
  vary, so a canned repeat rejects after the retry — deterministic.
- The retry message and the seen list ride in the user message, so
  `check.sh`'s assembled-message goldens and the per-field `voice` tool
  are unaffected.

## Gates

```
zig build                                    -> clean
make test                                    -> 308/308
KNAP_MCP_HOME=$(mktemp -d) make eval         -> converged 120/167 (unchanged)
sh knap-mcp/prompts/voice/check.sh           -> 36 ex, 240 mock, 0 warn/fail
zig fmt --check src; shellcheck run.sh       -> clean
eval/voice-tics/run.sh --corpus local --ledger mock
                                             -> pass; ledger stays empty
```

## Live re-measure (filed corpus, 2026-10-29)

vs the #382 baselines (devin-swe-2 base mild: tic 68%, lexicon 54,
repeat share 19%, density +5.8):

| run | records | changed | rejected | density + | tic runs | lexicon /100 | repeat share | repeats |
|---|--:|--:|--:|--:|--:|--:|--:|---|
| mild + ledger, swe-2 | 6 | 76 | 1 | +8.8 | 17% | 0 | **0%** | — |
| mild + ledger, glm-5.3-flash | 6 | 56 | 21 | +7.5 | 14% | 0 | **0%** | — |
| spicy, swe-2 (no ledger) | 6 | 63 | 14 | +8.1 | 33% | 17 | 13% | up ×6, just ×5, got ×4, damn ×4 |
| spicy + ledger, swe-2 | 5* | 50 | 11 | +8.1 | 28% | 10 | **0%** | — |

\* the harness shell was cut on the last record; the table is the five
complete reports. Under spicy the mechanism visibly works: 6 of 11
rejections are `repeats 'x' from an earlier record` / `added at run N`
(whole, point, nudges, single, like), the ledger accumulated 323 terms,
and repeat share went 13% → 0% on the same model and corpus. Mild
rejections were ordinary budget/format hits — under the stress tone
models add ~no words, so the ledger mostly never fires there, which is
exactly the desired end state. Residual "tic runs" are ironic-italic
emphasis, the tracked-but-deliberately-allowed remainder.

## For other lanes

- **filed batches**: share one `--ledger` file per batch so record N+1
  can't re-add what record N took. A rejected run keeps the original
  text — batches get quieter, not broken.
- **FILED-VOICE**: `voice.Seen` and the retry are in `voiceRun`; if
  another driver ever walks runs itself it needs the same loop.
- **VOICE-TICS**: `pr.sh` unchanged; score a batch's `added_terms` /
  ledger contents if you want term provenance without re-walking.
