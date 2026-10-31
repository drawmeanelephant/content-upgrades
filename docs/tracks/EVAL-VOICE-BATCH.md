# EVAL-VOICE-BATCH — broaden voice-tics evidence beyond the 6-record sample (#398)

Question: is a mild doc-voice batch over the filed archive now safe and
non-repetitive, and what should it cost? Baseline: docs/tracks/VOICE-TICS.md
(#382), tic runs 39–81%, repeat share up to 70% as shipped.

## What landed

- `knap-mcp/eval/voice-tics/corpus.txt`: 6 → 26 records, re-pinned to
  filed@3b668c16 (the #1057/#1058 batches were reverted by #1062/#1063 and
  #1059/#1060 never merged — all of main is pre-pass again). 7 mascots,
  7 lorelog, 6 reference, 6 posts/guides; 14 restored-batch records (same
  pre-pass text `pr.sh` scored), 12 fresh. The below-25 mascot/lorelog queue
  is exhausted, so fresh picks are in-band near the floor + 2 stubs + 1 audit.

## Sample (2026-10-30)

mild as shipped (= the adopted `stress` variant), 4 profiles × {plain,
--ledger}, 363 runs each. Full table + analysis is the report comment on
#398; artifacts under `~/.cache/knap-voice-tics-398/`.

Headline: lexicon 0/100 and repeat share 0% on every row; tic runs 12–30%
are *all* ironic italics; density +6.1–7.0. Verdicts: ship swe-2 (+ledger),
ship deepseek, ship spark **plain only**, don't ship glm yet.

## Findings that became issues

- **#400 (the big one):** knap-mcp never closes an ACP session after a
  successful prompt; `droid exec` caps ~49 open sessions, so every droid
  profile loses runs 50+ of long records (`session/new: Internal error`,
  deterministic, reproduced on retry). devin acp is unaffected.
- **#401:** extend the ledger to italicized terms — ironic italics are the
  only remaining tic and nothing guards them (12–30% of changed runs).
- **#402:** glm ignores mild's one-span budget — ~55–70% of its rejections
  are `mild: N formatting spans`; 15–19% discard rate. Fixed by spelling
  the budget out in mild.md ("one `*italic*` span and nothing else — no
  `**bold**`, `==highlight==`, `~~strikethrough~~`, no second `*italic*`"):
  on 6 corpus records (78 runs/side), span-budget rejections went 8→0
  and total rejections 11→2. Its remaining rejects drop apostrophes
  (U+2019), a different quirk.
- **#399:** `droid-deepseek` expect rejects the now-dated
  `deepseek-v4.1-flash-1017`; the eval ran via a private
  `KNAP_PROVIDERS_LOCAL` override (`expect='deepseek-v4.1-flash*'`).

## Oddities worth remembering

- `--ledger` is not free: it tripled spark's ironic italics (39→94) and
  doubled glm's rewording (24%→50%) — the growing "do not reuse" prompt
  suffix pushes weaker models toward *more* churn.
- `posts/coma-observation-transcript` (density 32.1) is unvoicable by mild:
  added words dilute the score (→28.1) and the proof refuses to store.
  The droid session cap eats its tail anyway.
- Dedup fired zero `repeats 'x'` rejections in ~2,900 runs — stress-mild
  adds formatting, not words, so word-dedup is nearly moot.
- One `adds narrator phrase 'quite'` (glm): the #388 guard's only catch.

## Gates

- `make test`: 308/308.
- `KNAP_MCP_HOME=$(mktemp -d) make eval`: converged 12/22 and 120/167.
- `run.sh --corpus filed mock` over the new 26-record corpus: 363 runs,
  scorer invariants hold.
