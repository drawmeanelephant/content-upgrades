# FILED-POL — per-collection scoring policy (#255)

## What landed

- `knap-mcp/src/policy.zig`: `knap-policy/1` loader with strict
  validation, plus `match`, `judge`, `policyScore`, `voiceAllowed` and
  `discover`. Schema spec: `docs/policy.md`.
- `knap-mcp/src/tools/audit.zig` reads the policy: `--policy <file>` /
  `--no-policy`, discovery (`$KNAP_POLICY`, then `<dir>/knap-policy.json`,
  then `<dir>/../knap-policy.json`), and `--below band`. Rows group by
  collection, JSONL rows get a `policy` field, the rollup gets band
  columns, and an `out of policy` list is added.
- `knap-mcp/policy/filed.json`: the worked example for filed.fyi.
- Shared one-liners in `main.zig`: the `policy.zig` test import, a
  `--policy` help line, and `--below <s|band>` in the help line.

## Decisions a reviewer should know

- **Annotate, never rewrite.** Policy adds a policy score and violations.
  The raw `total`, `density/3`, and every byte of the corpus are left
  alone. Audit still exits 0 when there are violations.
- **forbid vs exempt.** `exempt` drops the signal and re-normalizes over
  the weight that's left, so it doesn't drag the score and adding it
  earns nothing. `forbid` drops credit but does **not** re-normalize, so
  verse policy scores stay close to the raw scale and the #250 numbers
  still read the same. Any occurrence of a forbidden signal is a
  violation.
  - My first draft re-normalized forbidden signals too. That inflated
    limericks to a mean of 58 and a max of 94, which is meaningless.
- **Only exceeding the band's max is a violation.** Under `min` is an
  upgrade candidate (shown in `--below`), not a failure. Over `max` means
  the doc was over-upgraded, which is the vandalism the archive is
  resisting.
- **`--below <n>` with a policy**: a collection's `score.min` replaces
  `n` for its docs. `--below band` drops the global fallback.
- **Unpoliced docs** are grouped as `unpoliced:<default group>` and get
  `"policy":{"collection":null}`. `voiceAllowed` returns false for them.
- **Without a policy, output is byte-identical.** I checked this with
  `cmp` against the pre-change binary on filed:
  `audit content --below 20`, 4,022 lines.

## Verification (filed@ce44821f, 2,552 docs)

`audit content --policy knap-mcp/policy/filed.json --below band`:

| collection | n | policy mean | raw mean | band | in | below | oop | state |
|---|---|---|---|---|---|---|---|---|
| lorelog | 208 | 30.7 | 30.7 | 25–75 | 148 | 60 | 0 | ok |
| reference | 132 | 29.6 | 29.6 | 25–75 | 106 | 26 | 0 | ok |
| mascots | 256 | 28.9 | 28.9 | 25–75 | 166 | 90 | 0 | ok |
| changelog | 248 | 25.3 | 25.3 | –50 | 248 | 0 | 0 | ok |
| limericks | 574 | 21.4 | 16.7 | 0–35 | 574 | 0 | 0 | ok |
| aphorisms | 565 | 17.6 | 13.9 | 0–35 | 565 | 0 | 0 | ok |
| haikus | 543 | 7.3 | 5.8 | 0–20 | **543** | 0 | 0 | ok |

- `out of policy (0 docs)`. The upgrade queue (`below band`) has 176
  docs, all of them mascots, lorelog or reference. It includes 18
  reference stubs of about 33 words.
- **Hypothetical vandalized haiku.** I copied `hai-003` and appended a
  table. Result: `out of policy (1 doc): haikus/hai-999-vandalized.md
  forbid:tables=1`, and the JSONL row carries the violation. The
  untouched copy kept the same sha before and after.
- **Typos fail loudly.** `"mean_max"` →
  `policy …: collections[0].score: unknown key 'mean_max' (allowed: min,
  max, mean_min)`, exit 1.
- **Gates.** `make test` passed 246/246 after rebasing on main (5 new tests across policy.zig
  and audit.zig). `make eval` converged 120/167 on mock (unchanged).

## For other lanes

- **FILED-VOICE (#257)**: use `policy.voiceAllowed(p.match(rel), tone,
  region)`. The regions are `paragraphs`, `verse`, `list_items` and
  `headings`, and the walker classifies them. `verse` means hard-broken
  line groups. In the filed example only `paragraphs` and `list_items`
  are granted, and only outside verse collections.
- **Ratchet**: not wired here, because `ratchet.zig` isn't in this lane.
  The obvious hook is to skip any slot whose signal the doc's collection
  marks `forbid` or `exempt`, and to stop when `score.max` or a `cap`
  would be crossed.
- **Captain**: `docs/SPEC.md` should point to `docs/policy.md` for the
  policy file schema, and the README should mention `--policy`.
- **Filed maintainer**: the bands are measured recommendations. The tones
  per collection (mild only for aphorisms, changelog and releases; up to
  feral for mascots, lorelog and reference) are judgment calls to revisit.
