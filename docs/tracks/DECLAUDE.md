# DECLAUDE — strip invisible marks, fold lookalikes, flag what stays (#412)

Anthropic now marks Claude-generated text with "an imperceptible
watermark woven into the text itself" (EU AI Act Art. 50(2)). The
mechanism is undisclosed; the mechanically-addressable families are
character-level: invisible format chars, whitespace steganography,
lookalike punctuation, homoglyphs. `declaude` is the hygiene tool for
them — same job as `format_check` and the voice `no-control-characters`
guard (#333), but for marks and lookalikes rather than style.

## What landed

| Path | What |
|---|---|
| `knap-mcp/src/declaude.zig` | Pure logic: one code-point pass classifies, transforms and tallies; a second pass flags. `run(arena, text, opts) -> Result`, `writeJson`, `mergeEntries` for the record path. Contract version `declaude/1`. |
| `knap-mcp/src/tools/declaude.zig` | `knap_declaude` tool (`text`, `data`, `normalize`, `report`) plus the `declaude` CLI custom fn. |
| `knap-mcp/src/tools.zig`, `knap-mcp/src/main.zig` | Registry line; CLI row, help lines, two test imports. |

## The three tiers

- **strip** (default): removes the invisible set — ZWSP/ZWNJ, word
  joiner, soft hyphen, mid-text BOM, LRM/RLM, bidi embeddings and
  isolates (U+202A–E, U+2066–9), invisible operators (U+2061–4),
  interlinear anchors, the tag block U+E0000–E007F, supplementary
  variation selectors U+E0100–E01EF. Folds Unicode space variants
  (NBSP, U+2000–A, narrow NBSP, figure/thin space, ideographic space,
  ogham, medium math space) to ASCII space, and drops trailing
  spaces/tabs per line — the trailing-whitespace bit-encoding vector.
  Per-codepoint tally under `stripped`, `action` `removed` or `space`.
- **normalize** (`--normalize`, opt-in): canonicalizes visible
  lookalikes to ASCII — dashes U+2010–2015 and minus U+2212 to `-`,
  curly quotes U+2018–201F to `'`/`"`, ellipsis U+2026 to `...`.
  Single `-` (not `--`): one output char per mark, matching what ASCII
  prose actually carries. Lossy by design; each substitution is tallied
  under `normalized` with its `to`.
- **flag** (always on, never rewrites): Cyrillic/Greek confusables in
  whitespace-delimited tokens that also carry an ASCII letter — the
  mixed-script homoglyph signature; a pure Cyrillic word is legitimate
  text and unflagged. Also C0/C1 controls and U+2028/9 (the #333
  escapees), undecodable bytes (passed through untouched), and a small
  slop-phrase list (delve*, a testament to, it's worth noting, …).

Keep set, never stripped: ZWJ U+200D (holds emoji sequences together),
BMP variation selectors U+FE00–FE0F (VS15/VS16 are legitimate
emoji/text presentation), combining marks, and a U+FEFF at offset 0 —
a real signature; the mark vector is mid-text.

## Interface

```sh
knap-mcp declaude <doc_id|file|-> [--normalize] [--report]
```

`--report` detects without rewriting: `text`/`data` come back
byte-identical, `changed` reports "would change". MCP `data` mode
cleans every string in a record in place and emits `"data"` with the
aggregated tallies.

Report shape:

```json
{"version":"declaude/1","normalize":false,"report":false,"changed":true,
 "stripped":[{"codepoint":"U+200B","name":"zero width space","action":"removed","count":1}],
 "normalized":[{"codepoint":"U+2014","name":"em dash","action":"substituted","to":"-","count":1}],
 "flagged":[{"codepoint":"U+0435","name":"homoglyph","detail":"cyrillic letter, looks like 'e'","action":"flagged","count":1}],
 "text":"..."}
```

## Honest limits

- If Anthropic's mark is statistical (token-distribution), no
  mechanical strip removes it — only paraphrase does. This tool handles
  character-level marks and *reports what it found*, which is honest
  either way.
- Em dashes and friends are stylistic *tells*, not watermarks.
  Normalizing them removes no actual mark and is lossy — hence opt-in,
  never default.
- Dropping trailing whitespace erases markdown two-space hard breaks.
  Accepted: trailing spaces are the steganography vector, and generated
  markdown shouldn't lean on invisible semantics anyway.
- Flagged findings are reports, not rewrites — a wrong homoglyph guess
  corrupts real text, and regex-rewriting slop produces garbage.

## Gates

```
zig build                                -> clean
make test                                -> 327/327
KNAP_MCP_HOME=$(mktemp -d) make eval     -> converged 12/22 + 120/167 (unchanged)
```
