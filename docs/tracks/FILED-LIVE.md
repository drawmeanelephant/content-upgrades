# FILED-LIVE — doc-voice over the filed archive on a live model

Evidence run for #250 (filed.fyi wave). First live-backend `doc-voice`
batch over the real archive: every earlier doc-voice number was mock or
canned (`--replies`).

- **Model:** `nemotron-3.5-super` via `droid exec --output-format acp`
  (`reasoningEffort: none`), i.e. the `droid-nemotron` profile in
  `scripts/providers.sh`. Smoke 6/6, ~1.2 s/call.
- **Base:** knap-mcp @ `96f985e`, filed @ `ce44821f`
  (2,552 pages staged by publish-check), policy
  `knap-mcp/policy/filed.json`, raw staging + `themes/cantilever`.
- **Sample:** 15 records across every voice-eligible collection plus one
  haiku and one limerick (policy-denied control). All `--dry-run`: no
  bytes were written into `~/dev/filed.fyi` (`git status` clean after).
- **Dedup:** one shared `--ledger` for the batch — 243 terms recorded;
  a term one record adds is closed to the rest.

## Results

`seen` = prose runs sent to the model (one call each, plus one retry on
a ledger-dup rejection); `rej` = guard rejections (original kept
verbatim). Every run exited `ok` with all four proofs —
structhash `--ignore-formatting`, frontmatter bytes, wiki-link targets,
protected-atom order — and publish-check ok under the raw profile.

| record | tone | seen | rewritten | rej | density |
|---|---|--:|--:|--:|---|
| mascots/258.pocket-consensus | mild | 15 | 12 | 1 | 24.2 → 30.7 |
| mascots/203.cinder-forgememo | spicy | 20 | 12 | 7 | 35.5 → 36.2 |
| mascots/206.diesel-dkdriller | feral | 20 | 9 | 10 | 37.0 → 38.0 |
| lorelog/LLG-0365-BAIT-B2A | mild | 12 | 12 | 0 | 20.5 → 29.5 |
| lorelog/OCV-0409-TSC | spicy | 12 | 6 | 6 | 26.0 → 27.3 |
| reference/fref-0827-tsxl | mild | 20 | 14 | 3 | 34.9 → 43.0 |
| reference/fref-0280-cbnd | feral | 36 | 18 | 17 | 33.3 → 34.3 |
| aphorisms/APH-003 | mild | 9 | 6 | 0 | 18.5 → 18.5 |
| aphorisms/APH-005 | mild | 12 | 10 | 0 | 26.0 → 26.0 |
| changelog/2026-08-07-fnf-voice-004 | mild | 7 | 5 | 2 | 17.3 → 18.1 |
| releases/v0.1.2 | mild | 10 | 9 | 1 | 34.0 → 37.2 |
| posts/replacement-without-release | mild | 12 | 11 | 1 | 18.4 → 27.7 |
| guides/managed-absence-and-forms | spicy | 13 | 6 | 1 | 4.2 → 12.4 |
| haikus/hai-003 | mild | 0 | — | — | denied, 0 calls |
| limericks/LIM-FREF-0500 | mild | 0 | — | — | denied, 0 calls |

Totals: 198 model calls, 130 rewritten (66%), 49 rejected (25%), ~40 min
wall including publish-check staging per record.

## Rejection rate by tone

| tone | seen | rejected | rate |
|---|--:|--:|--:|
| mild | 97 | 8 | 8% |
| spicy | 45 | 14 | 31% |
| feral | 56 | 27 | 48% |

Failure classes seen (feral, reference/fref-0280): disallowed emoji
(U+1F3DA, U+1F4A5, U+1F4A9, U+1F4C4, U+1F5D1, U+1F5FA, U+1F643, U+1F921)
and stray U+FE0F; byte-budget blowouts (a 1,593-byte reply against a
53-byte cap); dropped proper nouns; content-word loss (`keeps only 2 of
8 input content words`). Every one kept the original paragraph and is
counted in `guard_rejections`.

## Reading

- **mild is shippable.** Insert-only emphasis diffs in the archive's
  voice; 8% waste. nemotron-3.5-super is a plausible default backend for
  the mild upgrade-queue pass — fast and cheap.
- **spicy/feral work but burn calls.** The doc still lands safe (the
  guard does its job); you just pay ~2–6× in rejected calls. Feral on a
  36-paragraph reference record took 9 min vs ~2 min mild.
- **Denied is free.** haikus/limericks exit in <1 s with zero calls —
  safe to run a corpus-wide loop without pre-filtering.
- **Doc-prompt gap still stands** (FILED-VOICE follow-up): the live
  voice prompt was written for template fields; a doc-specific section
  would likely cut the spicy/feral rejection rate.

## Reproduce

```sh
cfg=$(mktemp -t knap-droid-nemotron)
printf '{"model":"nemotron-3.5-super","reasoningEffort":"none"}\n' >"$cfg"
export KNAP_ACP_AGENT="droid exec --output-format acp --settings '$cfg'"
export KNAP_MCP_HOME=$(mktemp -d) KNAP_ACP_CWD=$KNAP_MCP_HOME
export KNAP_BORIS_SITE=~/dev/filed.fyi KNAP_BORIS_STAGING=raw \
       KNAP_BORIS_THEME=themes/cantilever KNAP_BORIS_PATH=~/dev/filed.fyi/bin/boris

knap-mcp doc-voice ~/dev/filed.fyi/content/mascots/258.pocket-consensus.md \
  --tone mild --policy knap-mcp/policy/filed.json --backend acp \
  --report report.json --ledger ledger.txt
```

Per-record reports, patched docs and the ledger from this run live under
`~/.cache/knap-filed-voice/nemotron-super/` on the run host (scratch, not
committed — the table above is the evidence).
