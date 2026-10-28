# eval/voice

The voice proof (SPEC demo beat 6): one template, one data file, three tones. Every tone renders with the same *normalized* structure hash as the original — `knap-mcp structhash --ignore-formatting`, which drops `strong`, `em`, `del`, `hl` and `code` tokens — and every voiced doc differs from the original as a string. The model rewrote words (and may now insert `**bold**`, `*italic*`, `~~strike~~`, `==highlight==`, code spans and allowlisted emoji); the layout and every fact didn't move.

```sh
knap-mcp/eval/voice/run.sh     # prints two tables, exits 0 when every row passes
```

It needs `jq` and the pinned engines (it runs `scripts/engines.sh env` when `KNAP_K4O_PATH` / `KNAP_DOGBED_PATH` are unset). It builds `knap-mcp` if `zig-out/bin/knap-mcp` is missing and uses a fresh `KNAP_MCP_HOME` unless one is set.

## What it does

For each template (verdict, apparatus, release-notes, reading-note, runbook) — 15 template×tone rows:

1. **Voiced data.** For each tone, `apply-mock.jq` applies `prompts/voice/mock/<tone>.jsonl` to `data/<template>.sample.json`. A line applies when its `template` matches and the value at its `field` path equals its `input`. This is the reference. When `knap-mcp voice` exists (lane C1), the script also runs `knap-mcp voice <id> -d <data> --tone <t> --backend mock` and fails if its `.data` differs from the reference.
2. **Render and hash.** For each target (markdown via k4o, html via dogbed), it renders the original and the three voiced files and hashes each with `knap-mcp structhash --ignore-formatting`.
3. **Row verdict.** A row passes when all four normalized hashes are equal and each voiced doc differs from the original byte for byte. A template with no mock lines shows `no mock coverage` and does not fail; partial coverage (some tones only) or mock lines that no longer match the sample data (`stale mock`) do fail. `fields changed` counts the string values each tone rewrote (mild/spicy/feral). Separately, each template's feral mock data must contain more formatting characters and emoji than the original — the eval proves the reply actually used the formatting budget, not just that it could have.

Then three negative controls, which must change the *exact* hash (no `--ignore-formatting`) in both targets:

- `markup`: verdict's `take` gains `**boring**`.
- `newline-list`: verdict's `take` gains a line break followed by `- `, which starts a list.
- `strip-markup`: verdict's `summary` drops `**durable**` relative to a source that carries it. Removal drifts the hash as surely as injection.

They show the exact hash still catches layout drift (and formatting drift — `markup` and `strip-markup` are invisible to the normalized hash by design; the voice guard's insert-only check is what catches those in real replies).

Then three guard controls run `knap-mcp voice --backend mock` with a private `KNAP_PROMPTS_DIR` holding replies that must be rejected, original kept:

- `strip-markup`: the reply drops the input's `**`.
- `meta-prose-wrap`: the reply is `Sure! Here is the take: ` plus the input verbatim.
- `footnote-bang`: the reply for release-notes `breaking[0].fix` — a `footnote_abutting` field on an element with a `note` — ends with `!` (`![^n]` renders as image syntax).

## The structure hash

`src/structhash.zig`; CLI `knap-mcp structhash <doc_id|file>... [--target markdown|html] [--explain] [--strict] [--ignore-formatting]`; MCP tool `knap_structure_hash({doc_id, ignore_formatting})`. It drops every text leaf and hashes the remaining block and inline kind sequence with Wyhash. `--explain` prints the tokens, one per line, indented by depth. `--ignore-formatting` also drops the inline kinds `strong`, `em`, `del` and `code` (markdown) and bare `<strong>`/`<em>`/`<del>`/`<code>` tags (html), so two docs that differ only in inserted inline formatting hash the same. `isFormatting` names those kinds; the voice guard uses the same list for its insert-only check. The format comes from `--target`, else the file or artifact extension, else sniffing.

- Markdown keeps frontmatter key names and list shapes (values are dropped, since a slug derives from the title), heading levels, paragraphs, lists and nesting, quotes, callouts with their `[!type]` and fold marker, table column count, alignment and cells per row (padding is ignored), code fences and their language, rules, footnote definitions, and the inline kinds: strong, emphasis, strikethrough, code, links, images, wikilinks (with or without a label), embeds, footnote refs, raw URLs, inline html, hard breaks. A `**` that pairs with nothing becomes a `delim:*` token, so even a stray marker moves the hash.
- HTML keeps tag names, nesting, attribute names, and the values of layout attributes (`class`, `type`, `colspan`, `rowspan`, `align`, `start`, `style`, ...). Text and text-derived values (`id` slugs, `alt`, `title`, `href`, `src`) are dropped.
- `--strict` also keeps link, image, wikilink and embed targets and footnote labels (markdown), and `href` and `src` (html).

## Coverage

Mock replies cover the 80 `voice: true` sample values across all five templates (verdict 8, apparatus 4, release-notes 24, reading-note 21, runbook 23), so every row counts. A template whose mock lines go missing shows `no mock coverage` and does not fail — new voice fields need mock lines to exercise the proof. A flagged field with no matching mock line stays `unchanged` under `knap-mcp voice --backend mock`, and the script warns on it — that warning is the signal a new voice field needs mock lines. Hashes depend on the engine pins, so a pin bump can change every hash; the eval only compares hashes within one run.
