# MD-DN: density/3 — ordered/task/math kinds; math spans opaque (#224)

Lane files: `knap-mcp/src/density.zig`, `knap-mcp/eval/density/README.md`,
`docs/density-eval.md`, `docs/tracks/MD-DN.md`.

## What landed

`density/2` → `density/3`. Three scorer changes, one table change:

- **`Kind` split.** `list` is now three kinds: `ordered` (first marker
  `N.`/`N)`), `task` (first item's content starts `[ ]`/`[x]`/`[X]`), and
  `list` (anything else). New kind `math` for a closed `$$` display block.
  13 kinds total; a numbered list, checklist, or math block now earns
  variety credit on docs that were already saturated.
- **Math is opaque.** A line that trims to `$$` opens a block that closes
  at the next one; those lines are not prose words and never reach the
  inline scan (same treatment as fenced code; unclosed = no credit). Inline
  `$…$` spans are skipped by the scanner — not styled runs, not coverage,
  not URL candidates — and are excluded from `words`, so math content
  counts for nothing either way. The span rule is pandoc's: opener `$`
  followed by a non-space, non-`$`; closer `$` preceded by a non-space and
  not followed by a digit (`$400 or $500` stays prose). Duplicated in
  `mathSpanEnd` rather than imported; must match `structhash.zig` (lane
  MD-SH implements the same rule there).
- **`block_variety` `sat` 6 → 8.** Keeps a gradient for the ratchet now
  that shipped samples were pinned at the old ceiling.

Notes:

- Neither `knap-mcp/eval/density/README.md` nor `docs/density-eval.md`
  contained a `density/2` version string — nothing to update there.
- `knap-mcp/src/tools/density.zig` still says `density/2` in its tool
  description — outside this lane's files; the captain refreshes
  published numbers elsewhere.

## Probe (`knap-mcp density /tmp/md-probe.md`)

| signal | density/2 | density/3 |
|---|--:|--:|
| scorer | `density/2` | `density/3` |
| words | 39 | 33 |
| block_variety raw | 5 | **8** (heading, ordered, task, list, paragraph, quote, math, rule) |
| styled_runs raw | 3 | **2** (`*c*` inside `$…$` no longer a run) |
| emphasis_variety raw | 3 | **2** |

## Fixture table — before (density/2, `a03bd3a`)

| fixture | words | total | top signals | penalties |
|---|--:|--:|---|---|
| `apparatus.md` | 215 | **70.7** | footnotes 12.0, tables 10.0, wikilinks 7.0, fragment_links 4.0, links 6.0, frontmatter 6.0, styled_runs 5.0, styled_coverage 6.0, emphasis_variety 4.0, heading_levels 3.0, heading_density 4.0, block_variety 8.0 | overload -5.0 |
| `confetti.md` | 73 | **0.0** | tables 3.7 | raw_urls -6.0, overload -15.0, format_check.raw-url-count -2.0 |
| `dense-ideal.md` | 193 | **93.6** | callouts 10.6, footnotes 11.6, tables 9.7, wikilinks 6.8, embeds 3.9, fragment_links 3.9, links 5.8, frontmatter 5.8, styled_runs 4.8, styled_coverage 5.8, emphasis_variety 3.9, heading_density 3.9, lists 3.9, block_variety 7.7 |  |
| `flat-barf.md` | 357 | **7.5** |  |  |
| `generic.md` | 227 | **18.8** | styled_runs 4.4, styled_coverage 3.1, heading_density 4.0, lists 4.0, block_variety 4.0 | format_check.list-heavy -4.0 |
| `reading-note.md` | 463 | **71.0** | callouts 10.1, footnotes 12.0, tables 10.0, wikilinks 7.0, embeds 4.0, fragment_links 4.0, frontmatter 6.0, heading_density 4.0, block_variety 8.0 | overload -5.0 |
| `reading-note.min.md` | 142 | **31.9** | callouts 7.8, links 4.3, frontmatter 4.3, block_variety 3.8 |  |
| `release-notes.md` | 451 | **82.8** | callouts 11.0, footnotes 12.0, tables 10.0, wikilinks 7.0, embeds 4.0, fragment_links 4.0, links 5.3, frontmatter 6.0, heading_levels 3.0, heading_density 4.0, block_variety 8.0 |  |
| `release-notes.min.md` | 176 | **39.2** | callouts 9.7, links 5.3, frontmatter 5.3, styled_runs 4.4, heading_density 3.5, block_variety 4.7 |  |
| `verdict-v1.html-table.md` | 132 | **17.7** | tables 6.6, wikilinks 4.6, frontmatter 4.0, block_variety 5.3 | raw_urls -6.0, format_check.unused-footnote -4.0, format_check.raw-url-count -2.0 |
| `verdict-v1.pipe-table.md` | 132 | **17.7** | tables 6.6, wikilinks 4.6, frontmatter 4.0, block_variety 5.3 | raw_urls -6.0, format_check.unused-footnote -4.0, format_check.raw-url-count -2.0 |
| `verdict.md` | 210 | **77.4** | callouts 4.5, footnotes 12.0, tables 10.0, wikilinks 7.0, embeds 4.0, fragment_links 4.0, links 6.0, frontmatter 6.0, styled_runs 5.0, styled_coverage 3.2, heading_density 4.0, lists 4.0, block_variety 8.0 | overload -5.0 |

## Fixture table — after (density/3)

| fixture | words | total | top signals | penalties |
|---|--:|--:|---|---|
| `apparatus.md` | 215 | **68.7** | footnotes 12.0, tables 10.0, wikilinks 7.0, fragment_links 4.0, links 6.0, frontmatter 6.0, styled_runs 5.0, styled_coverage 6.0, emphasis_variety 4.0, heading_levels 3.0, heading_density 4.0, block_variety 6.0 | overload -5.0 |
| `confetti.md` | 73 | **0.0** | tables 3.7 | raw_urls -6.0, overload -15.0, format_check.raw-url-count -2.0 |
| `dense-ideal.md` | 193 | **93.6** | callouts 10.6, footnotes 11.6, tables 9.7, wikilinks 6.8, embeds 3.9, fragment_links 3.9, links 5.8, frontmatter 5.8, styled_runs 4.8, styled_coverage 5.8, emphasis_variety 3.9, heading_density 3.9, lists 3.9, block_variety 7.7 |  |
| `flat-barf.md` | 357 | **6.8** |  |  |
| `generic.md` | 227 | **17.8** | styled_runs 4.4, styled_coverage 3.1, heading_density 4.0, lists 4.0, block_variety 3.0 | format_check.list-heavy -4.0 |
| `reading-note.md` | 463 | **70.0** | callouts 10.1, footnotes 12.0, tables 10.0, wikilinks 7.0, embeds 4.0, fragment_links 4.0, frontmatter 6.0, heading_density 4.0, block_variety 7.0 | overload -5.0 |
| `reading-note.min.md` | 142 | **31.0** | callouts 7.8, links 4.3, frontmatter 4.3 |  |
| `release-notes.md` | 451 | **81.8** | callouts 11.0, footnotes 12.0, tables 10.0, wikilinks 7.0, embeds 4.0, fragment_links 4.0, links 5.3, frontmatter 6.0, heading_levels 3.0, heading_density 4.0, block_variety 7.0 |  |
| `release-notes.min.md` | 176 | **38.0** | callouts 9.7, links 5.3, frontmatter 5.3, styled_runs 4.4, heading_density 3.5, block_variety 3.5 |  |
| `verdict-v1.html-table.md` | 132 | **16.4** | tables 6.6, wikilinks 4.6, frontmatter 4.0, block_variety 4.0 | raw_urls -6.0, format_check.unused-footnote -4.0, format_check.raw-url-count -2.0 |
| `verdict-v1.pipe-table.md` | 132 | **16.4** | tables 6.6, wikilinks 4.6, frontmatter 4.0, block_variety 4.0 | raw_urls -6.0, format_check.unused-footnote -4.0, format_check.raw-url-count -2.0 |
| `verdict.md` | 210 | **76.4** | callouts 4.5, footnotes 12.0, tables 10.0, wikilinks 7.0, embeds 4.0, fragment_links 4.0, links 6.0, frontmatter 6.0, styled_runs 5.0, styled_coverage 3.2, heading_density 4.0, lists 4.0, block_variety 7.0 | overload -5.0 |

Every fixture moves only through the `block_variety` `sat` 6→8 rescale —
none of the shipped samples contain `$$`, `$…$`, ordered, or task lists.
Ordering assertions (flat < generic < verdict < dense-ideal, confetti <
verdict, min + 15 < full, pipe ≈ html) all hold unchanged.

---

# MD-DN (#241): runbook min vs the `generic < min` invariant

Lane files: `knap-mcp/data/runbook.min.json`, `knap-mcp/src/density.zig`
(min-vs-sample fixture test), `knap-mcp/eval/ratchet.json`
(`runbook-min` floor), this note. Also re-rendered
`knap-mcp/eval/density/runbook.min.md`: it is the generated render of
`runbook.min.json` (README row: `knap-mcp render runbook -d
data/runbook.min.json --target markdown`), so it has to move with it.

## Decision: option 1 (richer min), not a per-template floor

The issue framed this as a trade-off: a fatter min raises the ratchet's
starting line and shrinks its measured gain. Measured, that trade-off
doesn't exist. Positive credit scales by `min(1, words/min_words)`
(`min_words = 200`), and that factor applies to the *climb* too. On a
40-word skeleton every slot the ratchet fills is worth about 0.2x, so
the thin min had the *smaller* gain:

| `runbook.min.json` | words | start | final | gain | stop |
|---|--:|--:|--:|--:|---|
| before (1 sentence, 1 phase, 3 steps) | 40 | 8.8 | 36.9 | 28.0 | max_iterations |
| after (3 sentences, 2 phases, 5 steps) | 111 | 23.6 | 60.7 | **37.1** | max_iterations |

`generic.md` is 17.8, so `generic < min` holds (23.6) with margin, and
`min + 15 < full` too (23.6 + 15 < 83.8).

Why not option 2 (a floor below `generic`):

- The old min broke its own shape. `summary`'s role says "2-4
  sentences"; the file had one. The new one has three. Fixing that alone
  is most of the word gap.
- A floor below `generic` would encode "a runbook skeleton is worse than
  generic prose" into the rubric's own regression test. That is wrong:
  the skeleton fell below generic only because of the length factor (a
  short-doc guard against token salad), not because it lacks structure.
  The invariant's job is to show that a template's bare required fields
  already beat unstructured prose. A per-template carve-out stops that
  check from covering the template that most needs it.
- It is still required fields only: `service`, `owner`, `severity`,
  `last_reviewed`, `summary`, `phases[].name`, `phases[].steps[].do`.
  No optional slot is pre-filled, so every slot the ratchet fills
  (`escalation`, `danger`, `preflight`, …) is still open from the start.
  The second phase adds the template's `---` break, which is required
  layout (phases are required), not optional apparatus.

## `runbook-min` floor 15 → 20

Measured gain is now 37.1. The old floor was 15 against 28.0, about
half the climb. 20 keeps about the same share of headroom (17 points)
and fails if the runbook climb loses roughly half its gain. The other
`*-min` cases stay at 15. Their measured gains (43.8, 55.5, 39.1) are
unchanged by this lane.

## Gate (pinned engines, mock)

- `make test`: all 209 tests passed, with `runbook` in the
  min-vs-sample `inline for`.
- `KNAP_MCP_HOME=$(mktemp -d) make eval`: converged 120/167, controls
  2/2 clean (no change; the seeds don't touch runbook data).
- `KNAP_MCP_HOME=$(mktemp -d) make ratchet-eval`: all expectations met;
  `runbook-min` 23.6 → 60.7, gain 37.1, check ok. No other row moved.
