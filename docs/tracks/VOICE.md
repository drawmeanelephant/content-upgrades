# Track VOICE: voice rewrites — inline emphasis + emoji (issue #196)

Lane VOICE. Owner files: `knap-mcp/src/voice.zig`, `knap-mcp/src/structhash.zig`,
`knap-mcp/src/tools/{structure_hash,voice}.zig`, `knap-mcp/src/main.zig` (usage
line), `knap-mcp/prompts/voice/*`, `knap-mcp/eval/voice/*`, `scripts/live.sh`
voice suite, this note.

## What changed

The voice contract used to be "one line of text, no markup ever added."
Replies may now insert constrained inline formatting — `**strong**`, `*em*`,
`==highlight==` around the phrase a skimmer must not miss (it may cover the
input's own words — it re-points, it doesn't retract), `~~del~~` around words
the reply added (strike may only cover the reply's own words), single-backtick
code spans that quote text already in the input — and allowlisted emoji
within a per-tone budget. Facts, layout and the template still own everything
else. `==highlight==` landed with MD-VH (#229); details live in
`docs/tracks/MD-VH.md`.

### Guard (`src/voice.zig`)

- W1 insert-only skeleton: the input's `structhash` inline token sequence must
  survive in order, with only formatting kinds (`strong`/`em`/`del`/`code`/`hl`,
  named by `structhash.isFormatting`) inserted. A code span wrapping `[^1]`
  or the input's own `**` still fails — the fnref/del disappears from the
  output sequence. Kinds only, not depths: inserted openers shift depth.
- W2 delimiter accounting: added `*` == `4·Δstrong + 2·Δem`, added backtick
  == `2·Δcode`, added `~` == `4·Δdel`, added `=` == `4·Δhl`. An added
  space-flanked `a == b`, a stray `==` or `===x===` resolves to no `hl`
  token, so it fails `unbalanced =`; an unmatched `==` also emits `delim:=`,
  which W1 rejects. `=` may be added but never dropped, like the other
  insertables. Stray delimiters emit `delim:` tokens which W1 also rejects;
  both run so a clear reason exists either way.
- W3 strike retraction: `~~x~~` may not contain a number token, any protected
  input token, a negation word, or an input content word (stemmed).
- W4 plain slots: roles containing `rendered bold`, `rendered italic`,
  `rendered highlight`, `alt text`, `page heading` or `frontmatter` take no
  added formatting or emoji — the slot is already styled or is copied into
  metadata/alt text. `rendered highlight` marks slots the template pipes
  through `| highlight`.
- W5 emoji classes: allowlist (U+1F300–1F5FF, 1F600–1F64F, 1F680–1F6FF,
  1F900–1F9FF, 1FA70–1FAFF, plus ✨⚡⚠✅❌☕, optional VS16) counts toward a
  tone budget; gestures/food/weapons/blood emoji, skin tones, ZWJ and other
  invisibles, a bare VS16, `‼`/`⁉` (reads as `!!`), astral symbols (fake
  bold etc.) and non-allowlisted dingbats are hard failures. Ordinary
  non-ASCII (—, ’, é) stays fine.
- W6 code spans quote the input: each added single-backtick span's text must
  occur verbatim in the input (`acmedb snapshot create` yes, a whole
  rewritten sentence no).
- Locked characters: `_ | # < > [ ] { } ^ @ \ " $` may neither be added nor
  dropped (`$` locked because dogbed renders `$…$` math and structhash can't
  see it). New hard rejects: added `![` (raw adjacency — `!**[^1]**` is fine),
  added HTML entities (`&#…;`/`&name;` smuggle `*` and emoji),
  `!!`/`??` checked on the delimiter-free projection (`wow!**!**` caught),
  ` ``` `/`~~~` fences added to the block-marker list.
- Length bounds now measure text only: `*`, `` ` ``, `~`, `=`, allowed emoji
  and VS16 don't count either way.
- Tone budgets (advisory → `warning:` reasons, mild profanity stays hard):
  mild ≤1 span, italic only — a `**`, `~~` or `==` span is a hard
  `mild: only *italic*`, not a warning — 0 emoji; spicy ≤2 spans, ≤1 emoji;
  feral ≤3 spans, ≤2 emoji. A highlight counts as one formatting span.
  Code spans quote the input and don't count.

### structhash (`src/structhash.zig`, `tools/structure_hash.zig`)

- `Options.ignore_formatting` + `pub fn isFormatting(kind)`. Markdown
  filtering happens at token emit (never by pre-stripping source), so code
  spans still hide their contents — `` `the **b**` `` normalizes to `p`
  like plain text, which is exactly the hole the guard's W1 covers.
- HTML skips bare attribute-less `<strong>`/`<em>`/`<del>`/`<code>` opens and
  their matching closes (per-tag counters); attributed tags like
  `<code class="language-zig">` are kept — they carry semantics.
- CLI `--ignore-formatting`; MCP `ignore_formatting` (boolean-validated,
  echoed in the result). `--strict` composes. Default output is
  byte-identical — frozen hash `6a738a8906ac2273` unchanged.

### Prompts, data, awk

- `system.md` rule 6 rewritten ("template owns the layout; you own the
  emphasis"): `==` sits in the kept-markup and allowed-add lists
  (`==highlight==` "on the phrase a skimmer must not miss"), `rendered
  highlight` is a plain-slot role marker, `==` is off the forbidden list.
  Rule 7 notes text-only length incl. `==` delimiters. Tone guides carry
  their formatting budget in their own voice. `Input:` line acknowledges
  markup.
- `voice.awk` mirrors the guard for the examples/mocks/selftest pipeline:
  locked vs insertable chars (`=` included), `*`-pairing (leftover
  comparison), `eqscan` pairs `==` runs with the same flanking rule zig
  uses, run-length checks for `` ` ``/`~`, emoji classes as UTF-8 byte
  ranges (LC_ALL=C), `textlen`, plain-role rule,
  `![`/entities/projection checks, span+emoji budgets (`==…==` counts as a
  span). `check.sh` is green: 36 examples, 240 mock replies, 51/51 selftest
  breaks.
- Examples: mild 1 italic, spicy `**one**`/code/emoji/`*called*` plus a
  `==mostly==`, feral `**DROPS MESSAGES**`/`~~peer review~~`/`==mostly==`
  /🪣/💀/🎁 plus a shared `` `quux migrate --to 3` `` example exercising W6.
  Mocks: feral formatted per template (≥8 values, all five kinds incl. a
  footnote-abutting slot and one `==…==` per shipped template), spicy ≥4,
  mild 2 italics; plain slots (verdict, subtitle, title, screenshot_alt)
  stay plain. Mock `field_role`s now equal the shape roles verbatim (a Zig
  test pins that).
- `testdata/bad.jsonl`: 51 lines — the `**hard pass**` verdict now expects
  `formatting in a plain slot`, 🖕 expects `adds disallowed emoji`, plus the
  earlier cases (dropped-markup-with-adds, unbalanced `*`/`` ` ``/`~`,
  `#`/`|`/`_`/`$` adds, `* `-list and ` ``` `-fence starts, plain-slot
  formatting and emoji, `![`, fake-bold, `!**!**` projection) and the `==`
  cases: `===x===` (the old now-legal `==shipped==` case), unbalanced `==x`,
  spaced `a == b`, `==` in mild, `==` in a plain slot and `plan==[^1]==`
  (zig reports `changes inline structure` + `unbalanced =`; awk has no W1
  so it reports `unbalanced =`).

### Eval / live

- `eval/voice/run.sh` main table compares `--ignore-formatting` hashes;
  negative controls keep the exact hash (drift must still move it); each
  template's feral data must add formatting (`fmtscore` jq counts
  `*`/`` ` ``/`~`/`=` plus emoji). `live.sh` `voice_suite` uses normalized
  hashes.

## Before/after

    voice "verdict" -d data/verdict.sample.json --tone feral --backend mock
    before: take = "the boring database that actually SHIPS, a whole miracle"
            (mock reply), no formatting anywhere, emoji = hard reject
    after:  take = "the **BORING** database that actually SHIPS, a whole
            miracle, put it in a museum" — guard passes, eval normalized
            hash equals the original's.

    knap-mcp structhash doc.md --ignore-formatting
    `the **boring** db` and `the boring db` hash equal; `the `**boring**` db`
    (hidden markup) also hashes equal — W1 in the guard is what catches it.

## Decisions

- Normalized equality is a *proof*, not a *guard*: formatting inside a code
  span is invisible to `--ignore-formatting`, so the guard does the
  insert-only check on tokens rather than comparing normalized hashes.
- Emoji in the input stays free; only *added* code points are classified.
- `‼`/`⁉` report `adds !!` because that's the failure they'd cause.
- A strike around the reply's own words is the only retraction-shaped
  formatting allowed; everything else about the input's meaning is frozen.
- `==` was hard-rejected only because structhash couldn't see it; with `hl`
  tokens (MD-VH, #229) the same W1/W2 machinery covers it. Unlike `~~`,
  `==` may wrap the input's own words — it re-points, it doesn't retract —
  so it has no W3-style rule.

## Known limits / follow-ups

- Skeleton matching is text-blind: moving `[^1]`'s sentence order or moving
  emphasis to a different word passes W1 (same token sequence). Acceptable —
  the facts check still pins the marker itself.
- Resolved: `README.md`, `docs/SPEC.md` and the shape descriptions used to
  claim the old "any markup fails" / "equal structure hash" guarantees — the
  doc-accuracy wave (#325) updated them to the constrained-inline-formatting
  contract.
- `~~` inside link text or footnote-def text is parsed as `del` by
  structhash like CommonMark; multi-backtick spans never resolve, so
  adding one fails `unbalanced ``.

- Fixed (#247, df64133): `voice.awk`'s `~` mirror now pairs by the same
  flanking rule as zig (`tildescan`), so `plan~~[^1]~~` fails both guards.
  The `==` mirror got the exact `eqscan` pairing in MD-VH.
- Word caps (`one-word`, `four word` roles) split on Unicode White_Space,
  not only ` \t\n` — NBSP, thin space, ideographic space and friends no
  longer evade the cap (#334, both guards).
- URL tokens end at whitespace, a quote, `<`, `>`, `)` or a backtick, so a
  code span may quote the input's URL the way W6 intends (#334).
- Trailing `.,;:!?` on a URL is the sentence's punctuation, not the
  target's, and **may change** (#334): `script: https://x/b` and
  `script, https://x/b,` carry the same URL. dogbed renders bare URLs as
  text and linkifiers exclude trailing punctuation, so the rendered
  target is unchanged; `examples/*.jsonl` already re-punctuate freely.
  This is the rule `prompts/voice/README.md` documents ("minus trailing
  `.,;:!?`").

