# AD: density/formatcheck audit fixes (#60, #61, #62, #63)

Lane files: `knap-mcp/src/density.zig`, `knap-mcp/src/formatcheck.zig`,
`knap-mcp/eval/density/**`.

## What landed

### Shared predicates (fixes rule-drift class of bugs)

formatcheck.zig now exports the line/inline predicates and density.zig
calls them — one definition each, so the scorer and the linter can't
disagree (the §1.1 debt):

`headingLevel` (accepts `#` + tab — the density semantics won),
`setextLevel`, `Fence`/`fenceOpen`/`isFenceClose` (tilde fences, indent
rules, backtick info strings), `listItem` (`-`, `*`, `+`, `N.`, `N)`),
`footnoteDefId` + `validFootnoteId` (whitespace ids rejected),
`isLinkDef`, `isRule`, `tableDelimiter`, `matchBracket`, `runLen`,
`countWords` + `wordByte` + `alnum` (CJK-aware counting, below).

### #61 — countBareUrls rewrite (formatcheck.zig)

One left-to-right pass per line tracking backtick-run code spans and
`[[ ]]` nesting — O(n) per line. 20k-URL single-line doc: **111 s →
0.03 s**. The same rewrite fixes the wikilink-exemption false negative:
`[[Page]] and https://x.com/a plus [[Other]]` now warns, because the
state is positional, not "any `[[` before and any `]]` after".

The single pass also skips `[label]` regions when followed by `(` or `[`
(a URL inside a link label isn't bare), `[^…]` footnote ids, and
backtick code spans — see #63.5/#63.6.

### #63 — six rule bugs

1. **CJK invisibility.** `countWords` counts each CJK ideograph/kana
   codepoint (Han ranges, kana, Kangxi/CJK radicals, ext. A/B) as one
   word — spaceless prose gets a real count. Other multibyte chars are
   word material (`café` = 1 word); Unicode spaces and punctuation/symbol
   blocks (incl. Latin-1 punct like `·`, em-dashes, emoji) are
   boundaries. `text_chars`/`styled_chars` count all non-ASCII bytes, so
   styled-coverage works on UTF-8 docs. Probe: ~7.6k Japanese chars →
   words 6404, not 4.
2. **Footnote bookkeeping.** `refs`/`defs` are `StringHashMapUnmanaged`
   (density) plus membership sets next to the ordered `Note` lists
   (formatcheck — warning order preserved). 20k refs + defs: **~15 s →
   0.12 s**.
3. **Tilde fences.** formatcheck uses shared `fenceOpen`/`isFenceClose`;
   fenced text no longer pollutes word/list/run counts. Also fixes
   `unclosed-fence` to warn on "fence still open at EOF" rather than
   parity.
4. **GFM tables.** A `tableDelimiter`-shaped row (`--- | ---`) now marks
   a table: it clears any pending wall-of-text run and keeps body rows
   (`|` lines) out of prose/run counts until a non-pipe line ends it.
5. **Link-label double penalty.** `[https://x/page](https://x)` scores
   links=1, raw_urls=0, no warning — density skips raw-URL counting while
   scanning a link label (`no_raw_urls` flag), formatcheck skips the
   label region via `linkLabelEnd`.
6. **"Bare" agreement.** formatcheck now skips `[x]: url` link-def lines
   (shared `isLinkDef`) and backtick code spans — matching density.
   Footnote defs stay exempt in formatcheck; density still scans `[^x]:`
   body text as prose (URLs inside defs count). Documented asymmetry,
   deliberate: def bodies are rendered prose.

### #62 — counting batch

- `+ ` items count as list lines in formatcheck (shared `listItem`).
- Setext headings (`===`/`---` under a prose line) count in both tools:
  density records heading level + kind inside `paragraph()`; formatcheck
  converts the previous prose line via `prev_para`. After a blank line or
  any non-paragraph line they stay rules/prose, matching CommonMark.
- Unterminated frontmatter: formatcheck precomputes the closer line
  (`frontmatterEnd`); if `---` never closes, its lines are processed as
  prose — same as density's re-scan (words counted, `key: value` runs can
  now warn).
- `#\tTitle` is a heading in both (shared `headingLevel`); `[^a b]` /
  `[^ ]` are not footnote refs in either (shared `validFootnoteId`).
- `pipeTableAt` requires the delimiter row's cell count to match the
  header's (`| a | b / | --- | / …` renders as prose in GFM).
- `max_span` scans now charge against a budget of `text.len + 8·max_span`
  per `inlines()` call; past it, the tail only feeds `text_chars`. 1 MB
  of `[`: **15.2 s → 0.06 s**.
- Item 7 (overload tax vs. word floor) is a design note — intended
  behavior; the #60 length factor already softens it.

### #60 — short-doc saturation → `density/2`

`score()` now multiplies positive-signal credit by
`length = min(1, words / min_words)` (folded into `normalized` so
`contribution = normalized * weight` still holds). Penalties are not
scaled. The 30-word salad that scored **100.0 now scores 14.5**.

Why this over the issue's other options: `words/500` would scale every
fixture under 500 words (the 193-word dense ideal would drop to ~37);
raising `sat` past 5 still grants ~83% credit per token at the floor.
The `min_words` pivot only affects docs genuinely under the floor.

## Calibration (`density/2`, all orderings hold)

| fixture | words | d/1 | d/2 |
|---|--:|--:|--:|
| `flat-barf.md` | 357 | 7.5 | 7.5 |
| `generic.md` | 227 | 18.8 | 18.8 |
| `confetti.md` | 73 | 14.5 | **0.0** |
| `cunty.md` | 193 | 97.0 | 93.6 |
| `apparatus.md` | 215 | 70.7 | 70.7 |
| `verdict.md` | 210 | 77.5 | 77.4 |
| `verdict-v1.pipe-table.md` | 132 | 33.0 | 17.7 |
| `verdict-v1.html-table.md` | 132 | 33.0 | 17.7 |
| `reading-note.md` | 459 | 66.9 | 66.9 |
| `reading-note.min.md` | 141 | 41.0 | **28.9** |
| `release-notes.md` | 449 | 78.8 | 78.8 |
| `release-notes.min.md` | 176 | 44.5 | **39.2** |

`min + 15 < full` and `generic < min` still hold for both T1 templates;
`|pipe − html|` stayed 0.0. The ratchet-eval corpus passes unchanged —
`min_gain: 15` cases now gain 32/39 (start scores dropped, finals didn't).

**ratchet.json / ratchet-mock.json untouched** — their `expect` keys are
thresholds (`min_gain`, `min_accepted`, `reject`), not pinned totals, and
all passed. **Docs lanes beware:** `docs/tracks/D1.md` and `D2.md` tables
pin the d/1 numbers (41.0/44.5/etc.) — those are now `density/2` history.
`tools/density.zig`'s description string still says "density/1" — out of
my lane, flagging for whoever owns it.

## Gates

- `zig build` / `zig build test`: green (incl. 12 new tests).
- `make test`: green.
- `KNAP_MCP_HOME=$(mktemp -d) make eval`: green — converged 120/167,
  mean iters 1.19, controls clean (same as pre-change).
- `ratchet-eval --backend mock`: all expectations met.

## What's left / for other lanes

- `tools/density.zig` description string ("density/1") — small edit,
  outside this lane.
- Footnote-def bodies: formatcheck exempts the whole line from raw-URL
  counting; density counts URLs in def bodies. Align if a lane cares.
- `eval/density/README.md` is unchanged; the score tables live in
  D1.md/D2.md.
