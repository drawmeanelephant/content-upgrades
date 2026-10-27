# Lane AV: voice audit fixes

Fixes for the Oct 26 audit of `src/voice.zig` (#54–#57 plus the CAPTAIN
trailing-`!` footnote hazard).

## What landed

**#54 — bidirectional markup guard.** The markup rule was presence-based,
additions only, so `the **boring** db` -> `the boring db` passed and
silently changed the structure hash. Now:

- `voice.zig` compares each markup char's *count* in input vs reply:
  `adds markup character X` / `drops markup character X`.
- The guard also compares `structhash.skeletonOpts` of input and reply
  as markdown and reports `changes inline structure` on any token
  difference — the same invariant the beat-6 proof hashes. This catches
  re-paired or moved markup the counts miss.
- `voice.awk` mirrors the count rule (it can't call structhash), and
  `system.md` rule 6 now says existing markup must survive. Two
  `bad.jsonl` cases cover dropped `**` and backticks; `eval/voice/run.sh`
  has a `strip-markup` negative control (summary drops `**durable**`)
  plus a guard-control section that runs `knap-mcp voice` against a
  private `KNAP_PROMPTS_DIR` and asserts the reply is rejected.

**#55 — contract/mock drift.** Resolution: unflagged. `blockers` and
`caveats` (verdict) and `caveats` (apparatus) are no longer `voice: true`.
Rationale: no mock lines existed for them, the README contract already
documented them as not rewritten, and flagging them meant a live backend
rewrote values the contract excluded while mock silently passed them
through. They stay in the README "Proposed" table, so re-flagging later
is a one-line shape change plus mock lines. `collect()` now yields the
documented 32 values: verdict 5, apparatus 1, release-notes 14,
reading-note 12.

**#56 — invisible slug moves.** `neverRewritten` now covers
`release-notes title` (its kebab-case is the frontmatter slug), and
`collect` skips `verdict.title` whenever `subject` is absent or empty
(the slug's `??` fallback). The release-notes shape drops its `voice`
flag on `title` and the three `title` mock lines went away; the README
never-list records both cases. `verdict.receipts[].evidence` also
renders `[^note]`-adjacent and `apparatus.receipts[].claim` likewise,
but `receipts` is a never-key at the top level so no flag is needed
there.

**#57 — guard robustness (items 1 and 3 only).**

- Rewrite check: for inputs with >= 3 content words the reply must keep
  at least half (`keeps only k of n input content words`), and a reply
  containing the input verbatim may not lead with >= 2 content words the
  input lacks (`wraps the input with extra prose` — the
  `Sure! Here is the take: ...` case). Content words are verifier.zig's
  normalize+tokenize+stem, re-implemented since its helpers are private;
  `verifier.normalize` is reused. Thresholds were calibrated so all
  129 example/mock lines pass — verdicts like `give a shit` ->
  `worth caring about` legitimately share no words, hence the >=3 gate
  and the verbatim-containment qualifier.
- Invalid UTF-8: `std.unicode.utf8ValidateSlice` on the reply; failure is
  a hard reject (`invalid UTF-8`), so bad bytes never reach the stored
  value or the JSON output. Not in bad.jsonl because its checker is
  byte-oriented awk and Zig's JSON parser rejects invalid UTF-8 lines;
  covered by a Zig unit test instead.
- Item 2 (requireData re-encodes numbers) is another lane's —
  `tools/common.zig` untouched.

**BONUS — trailing-`!` footnote hazard (landed).** Shapes mark
`footnote_abutting: true` on release-notes `breaking[].fix` and
`highlights[].what`, and reading-note `quotes[].why`. `collect` sets
`Slot.footnote_abutting` only when the element actually carries a
`note`, so mock lines on note-free elements (highlights[2],
quotes[2]) still pass with a trailing `!`. The guard takes the flag and
hard-rejects a reply ending in `!`. All in-lane files.

## Guard divergence note

`voice.awk` stays the reference for `check.sh` data validation; the Zig
guard additionally has checks awk cannot express (skeleton comparison,
UTF-8 validity, content-word overlap, the `footnote_abutting` flag,
which needs element context the JSONL lines don't carry). bad.jsonl
cases therefore only cover rules both implementations share.

## Gate output

- `zig build test` / `make test`: green (bad.jsonl now 21 cases).
- `prompts/voice/check.sh`: `33 examples, 96 mock replies, 21/21 selftest
  breaks caught, 0 warnings, 0 failures`.
- `eval/voice/run.sh`: pass — all structure hashes equal across tones,
  release-notes now 14/14/14 fields changed; 3 negative controls +
  3 guard controls all pass.
- `KNAP_MCP_HOME=$(mktemp -d) make eval`: converged 120/167 breaks
  (unchanged from baseline).
- `knap-mcp ratchet-eval --corpus eval/ratchet.json --backend mock`:
  all expectations met — shape unflagging needed no ratchet corpus edits.

## Left / other lanes should know

- `collect()` count changed: 39 -> 32 eligible values on the samples.
  Anything asserting per-template field counts sees release-notes at 14.
- `guard` gained a `footnote_abutting` parameter (slot-derived); callers
  outside `voice.zig` don't exist today.
- `Slot` gained a field; `guard`/`addValue` signatures changed.
- Item #57.2 (numbers re-encoded on the tool path, `tools/common.zig`
  `requireData`) is explicitly another lane's.
