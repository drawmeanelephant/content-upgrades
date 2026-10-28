# Track MD-VH: voice may add `==highlight==` (issue #229, wave 2)

Lane MD-VH. Owner files: `knap-mcp/src/voice.zig`, `knap-mcp/prompts/voice/**`,
`knap-mcp/eval/voice/**`, this note. Depends on #223 (structhash `hl`/`math`/
`mathblock` tokens, `isFormatting` covers `hl`/`/hl`/`<mark>`).

## What changed

`==` was hard-rejected only because structhash couldn't see it. With `hl`
tokens in, W1 (insert-only skeleton) already accepts inserted highlights —
this lane adds the accounting, budgets, prompt and the awk mirror. Unlike
strikethrough, highlight may cover the input's own words (it re-points, it
doesn't retract), so there is no W3-style rule.

### Guard (`src/voice.zig`)

- `=` joined `insertable` (`*`, `` ` ``, `~`, `=`): input `=` may not be
  dropped; adds are accounted for.
- W2: added `=` chars must equal `4·Δhl` — the `opened(so,"hl")` delta, same
  pattern as `~`/`del`. An added spaced `a == b`, a stray `==`, or `===x===`
  resolves to no `hl` token, so it fails `unbalanced =`. An unmatched `==`
  run also emits `delim:=`, which W1 rejects as `changes inline structure`.
- The `adds ==` hard reject is gone.
- Budgets: a highlight is one formatting span (`nspans += d_hl`). Mild stays
  italic-only: `mild: only *italic*` now also fires on `d_hl > 0`.
- W4: `rendered highlight` joined the plain-slot markers and `a_eq != 0`
  joined the check (slots the template pipes through `| highlight` take no
  added formatting).
- `textLen` and the `!!`/`??` projection now strip `=` too: `==` delimiters
  don't count toward length, and `!==!==` still reads as `!!`.

Notable shapes (verified against `structhash --explain`):

- `the ==plan[^1]== works` → `p hl fnref /hl` — legal: the fnref survives
  inside `hl`, so a proper wrap *is* allowed.
- `the plan==[^1]== works` → `delim:=` pairs around the fnref — `==` can't
  flank-hug `[`, so a tight wrap of just the marker fails W1 and W2.
- `a ===x=== b` and `a == b` emit no tokens at all — inert text that fails
  only the W2 char count.

### voice.awk

- `=` in `INSERT`; the `adds ==` reject removed.
- New `eqscan(s)`: hides code spans, then pairs `==` runs with the same
  flanking rule zig uses (open iff next isn't space — punctuation needs
  space or punctuation on the left; close iff prev isn't space — punctuation
  needs space or punctuation on the right; both => closer iff stack
  non-empty). Returns the resolved `hl` count.
- W2 mirrors zig exactly: `countchar(out,"=") - countchar(in_,"=")` must
  equal `4 * (hl_ou - hl_in)`. This is stricter than the `addruns`
  run-length pairing `~` still uses — `eqscan` catches `plan==[^1]==`
  (two closers, no opener) where pure run pairing would see balanced runs.
- `nspans` gains `hl_ou - hl_in`; the mild italic-only check and the
  plain-slot check gain `=`. `textlen` and the `!!`/`??` projection strip
  `=`.

### Prompts, examples, mocks, selftest

- `system.md` rule 6: `==` added to the kept-markup list, `==highlight==`
  allowed "on the phrase a skimmer must not miss", `rendered highlight`
  added to the plain-slot roles, `==` removed from the forbidden list.
  Rule 7 notes `==` delimiters don't count toward length.
- `mild.md`: "no highlight" added to its quiet-formatting line. `spicy.md`
  and `feral.md` list `==highlight==` in their span budgets, each with its
  own skimmer-phrasing.
- Examples: spicy `blockers[1]` and feral `blockers[1]` each carry a
  `==mostly==` (same input across tones, so the sequences stay aligned).
- `mock/feral.jsonl`: one `==…==` per shipped template — verdict
  `sources[0].quotes[1].used_for`, apparatus `sources[0].quotes[0].used_for`,
  release-notes `known_issues[0]`, reading-note `thoughts[0]`.
- `testdata/bad.jsonl`: the old `==shipped==` case (now legal) became
  `===x===`; appended unbalanced `==x`, spaced `a == b`, `==` in mild,
  `==` in a plain slot, and `plan==[^1]==`. 49 lines; every `expect` is a
  reason both zig and awk produce (awk has no W1, so `plan==[^1]==`
  reports `unbalanced =` — zig reports both `changes inline structure`
  and `unbalanced =`).
- `eval/voice/run.sh` `fmtscore` counts `=`; testdata goldens regenerated.

## Gates

    make test                                      PASS
    KNAP_MCP_HOME=$(mktemp -d) make eval           converged 120/167
    KNAP_MCP_HOME=$(mktemp -d) make voice-eval     voice eval: pass
    sh knap-mcp/prompts/voice/check.sh             49/49 selftest breaks, 0 failures
    make demo                                      all beats ok
    zig fmt --check src                            clean

Done-when: `voice release-notes --tone feral --backend mock` emits
`==HOURS==` in `known_issues[0]`, `rejected` 0; normalized hashes equal
across all three tones for every template; negative controls still move
the exact hash.

## Decisions

- `=` counting is raw-char (like zig's count): `=` inside code spans,
  `[^…]` labels or link targets doesn't form `hl` but still must net out
  to `4·Δhl` — so it fails `unbalanced =` rather than sneaking through.
- eqscan skips `[^…]`/link hiding (only code spans, like starscan): `=`
  inside a footnote label could pair up in awk where zig sees none, but
  such a reply trips the fact checks anyway.
- The `~` mirror keeps its weaker `addruns` run-length pairing; the
  equivalent `plan~~[^1]~~` gap predates this lane.

## Left for other lanes

- `docs/tracks/VOICE.md` still describes the `==`-rejects — VOICE lane
  owns that file.
- `eval/voice` could gain a `==`-bearing negative control pair; current
  controls cover `**` add/drop only — not required by the issue.
