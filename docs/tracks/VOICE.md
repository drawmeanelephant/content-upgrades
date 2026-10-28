# Track VOICE: voice rewrites — inline emphasis + emoji (issue #196)

Lane VOICE. Owner files: `knap-mcp/src/voice.zig`, `knap-mcp/src/structhash.zig`,
`knap-mcp/src/tools/{structure_hash,voice}.zig`, `knap-mcp/src/main.zig` (usage
line), `knap-mcp/prompts/voice/*`, `knap-mcp/eval/voice/*`, `scripts/live.sh`
voice suite, this note.

## What changed

The voice contract used to be "one line of text, no markup ever added."
Replies may now insert constrained inline formatting — `**strong**`, `*em*`,
`~~del~~` around words the reply added (strike may only cover the reply's own
words), single-backtick code spans that quote text already in the input — and
allowlisted emoji within a per-tone budget. Facts, layout and the template
still own everything else.

### Guard (`src/voice.zig`)

- W1 insert-only skeleton: the input's `structhash` inline token sequence must
  survive in order, with only formatting kinds (`strong`/`em`/`del`/`code`,
  named by `structhash.isFormatting`) inserted. A code span wrapping `[^1]`
  or the input's own `**` still fails — the fnref/del disappears from the
  output sequence. Kinds only, not depths: inserted openers shift depth.
- W2 delimiter accounting: added `*` == `4·Δstrong + 2·Δem`, added backtick
  == `2·Δcode`, added `~` == `4·Δdel`. Stray delimiters emit `delim:` tokens
  which W1 also rejects; both run so a clear reason exists either way.
- W3 strike retraction: `~~x~~` may not contain a number token, any protected
  input token, a negation word, or an input content word (stemmed).
- W4 plain slots: roles containing `rendered bold`, `rendered italic`,
  `alt text`, `page heading` or `frontmatter` take no added formatting or
  emoji — the slot is already styled or is copied into metadata/alt text.
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
  added `==`, added HTML entities (`&#…;`/`&name;` smuggle `*` and emoji),
  `!!`/`??` checked on the delimiter-free projection (`wow!**!**` caught),
  ` ``` `/`~~~` fences added to the block-marker list.
- Length bounds now measure text only: `*`, `` ` ``, `~`, allowed emoji and
  VS16 don't count either way.
- Tone budgets (advisory → `warning:` reasons, mild profanity stays hard):
  mild ≤1 span, italic only, 0 emoji; spicy ≤2 spans, ≤1 emoji; feral ≤3
  spans, ≤2 emoji. Code spans quote the input and don't count.

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
  emphasis"), rule 7 notes text-only length. Tone guides carry their
  formatting budget in their own voice. `Input:` line acknowledges markup.
- `voice.awk` mirrors the guard for the examples/mocks/selftest pipeline:
  locked vs insertable chars, `*`-pairing (leftover comparison),
  run-length checks for `` ` ``/`~`, emoji classes as UTF-8 byte ranges
  (LC_ALL=C), `textlen`, plain-role rule, `![`/`==`/entities/projection
  checks, span+emoji budgets. `check.sh` is green: 36 examples, 114 mock
  replies, 37/37 selftest breaks.
- Examples: mild 1 italic, spicy `**one**`/code/emoji/`*called*`,
  feral `**DROPS MESSAGES**`/`~~peer review~~`/🪣/💀/🎁 plus a shared
  `` `quux migrate --to 3` `` example exercising W6. Mocks: feral formatted
  per template (≥8 values, all five kinds incl. a footnote-abutting slot),
  spicy ≥4, mild 2 italics; plain slots (verdict, subtitle, title,
  screenshot_alt) stay plain. Mock `field_role`s now equal the shape roles
  verbatim (a Zig test pins that).
- `testdata/bad.jsonl`: 37 lines — the `**hard pass**` verdict now expects
  `formatting in a plain slot`, 🖕 expects `adds disallowed emoji`, plus 16
  new cases (dropped-markup-with-adds, unbalanced `*`/`` ` ``/`~`, `#`/`|`
  /`_`/`$` adds, `* `-list and ` ``` `-fence starts, plain-slot formatting
  and emoji, `![`, fake-bold, `!**!**` projection, `==`).

### Eval / live

- `eval/voice/run.sh` main table compares `--ignore-formatting` hashes;
  negative controls keep the exact hash (drift must still move it); each
  template's feral data must add formatting (`fmtscore` jq). `live.sh`
  `voice_suite` uses normalized hashes.

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

## Known limits / follow-ups

- Skeleton matching is text-blind: moving `[^1]`'s sentence order or moving
  emphasis to a different word passes W1 (same token sequence). Acceptable —
  the facts check still pins the marker itself.
- `README.md`, `docs/SPEC.md` and the shape descriptions still claim the old
  "any markup fails" / "equal structure hash" guarantees; those files are
  outside this lane's ownership — filed as a separate discrepancy issue.
- `~~` inside link text or footnote-def text is parsed as `del` by
  structhash like CommonMark; multi-backtick spans never resolve, so
  adding one fails `unbalanced ``.
