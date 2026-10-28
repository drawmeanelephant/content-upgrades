# FILED-TPL — filed record template pack + doc→data extraction

Issue #256. Lane owns: `src/tools/extract.zig`, `templates/filed-*.knap`,
`templates/shapes/filed-*.json`, `data/filed-*.json`, this note.

## What landed

- `knap_extract` MCP tool + `knap-mcp extract <doc_id|file> --template <id>`
  CLI (custom row; `<doc_id|file>` reuses `common.resolveDoc`).
- Doc model in `tools/extract.zig`: frontmatter (closed-schema values only),
  a verbatim preamble, and `<=h2` sections (`###+` nests inside its parent).
  A leading `# <title>` equal to fm `title` is consumed into `title_heading`.
- Canon slots come from the shape: `"section"` names the slot's canonical
  heading, `"preamble": true` marks the card/lede slot, `"match": "first"`
  prefers the earliest fuzzy hit (the personalized verse log beats a later
  generic `## Limerick Log`). Matching is exact normalized equality first,
  then canon-words-as-ordered-subset ("system messages" ⊂ "known system
  messages", "day in the life" ⊂ "day in the life vignette").
- Everything a canon slot cannot carry is never dropped: non-canon sections
  go verbatim into `extra_sections` (`{after, heading, level, body}`) and are
  re-emitted by the templates right after the canon slot they followed, so
  `extract → render` reproduces the record's section order; `unmapped`
  reports every non-skeleton range plus stray frontmatter keys.
- `round_trip` in the report renders the extracted data and compares
  `structhash --ignore-formatting` skeletons per region (preamble + each
  section, in doc order).
- `--data <ratcheted.json>` (or the tool's `data` arg) switches to fragment
  mode: for each canon slot that went empty→filled it emits the rendered
  section block, and for grown arrays the append delta — insert fragments
  keyed to sections (`after_slot`/`after_heading`/`before_heading`), never
  a whole re-rendered record.

## Templates

`filed-mascot`, `filed-lorelog`, `filed-reference` share a byte-identical
frontmatter prelude emitting only filed's closed keys (title, id, parent,
status, tags, relations, published_at, summary; a test pins it). Canon
bodies are verbatim strings; list slots (`relationships`,
`system_messages`, rendered via `| code` so values stay inert-safe) are
ratchet-growable. The upgrade apparatus — Field Testimony blockquotes with
keyed `notes` footnotes, a Field Notes palette (callout|quote|list), the
Provenance Ledger table, Annotations — sits at the end of the canon order,
so new slots write back as section fragments before EOF.

## Evidence

- `extract` on the three exemplars (`mascots/003`, `lorelog/LLG-0001-NAV`,
  `reference/fref-0030-avsg`): ok, data staged, `unmapped` covers every
  non-skeleton range, `round_trip` 18/18, 5/5, 18/18 sections equal.
- Thin mascot (`011.formee-formeson`, Image+Biography+verse only):
  `ratchet-eval --corpus <inline mock>` accepted 2 slots (31.7 → 42.9).
- `extract --data <ratcheted.json>` emitted `section` fragments for
  `system_messages`, `testimony`, `field_notes` anchored after
  `Limerick Log`/EOF; each fragment `format-check` clean (only the expected
  `skipped-heading` warning a standalone h2 fragment always shows).

## For later lanes

- Write-back applies `insert` anchors: `after_heading` + `before_heading`
  delimit where a `section` fragment lands (extras anchored to the same
  slot keep rendering before later canon — match that on splice).
- `eval/ratchet-mock.json` entries for `filed-*` would help `ratchet-eval`;
  not in this lane's file list, left for whoever owns eval data.
- `format-check` fragments warn `skipped-heading` (h0→h2) — a fragment is
  a slice, not a doc; write-back should format-check the merged result.

## Files not owned but needed

None required edits; `eval/ratchet-mock.json` additions noted above.
