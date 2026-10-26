# eval/voice

The voice proof (SPEC demo beat 6): one template, one data file, three tones. Every tone renders with the same structure hash as the original, and every voiced doc differs from the original as a string. The model rewrote words; the layout didn't move.

```sh
knap-mcp/eval/voice/run.sh     # prints two tables, exits 0 when every row passes
```

It needs `jq` and the pinned engines (it runs `scripts/engines.sh env` when `KNAP_K4O_PATH` / `KNAP_DOGBED_PATH` are unset). It builds `knap-mcp` if `zig-out/bin/knap-mcp` is missing and uses a fresh `KNAP_MCP_HOME` unless one is set.

## What it does

For each template (verdict, apparatus, release-notes, reading-note):

1. **Voiced data.** For each tone, `apply-mock.jq` applies `prompts/voice/mock/<tone>.jsonl` to `data/<template>.sample.json`. A line applies when its `template` matches and the value at its `field` path equals its `input`. This is the reference. When `knap-mcp voice` exists (lane C1), the script also runs `knap-mcp voice <id> -d <data> --tone <t> --backend mock` and fails if its `.data` differs from the reference.
2. **Render and hash.** For each target (markdown via k4o, html via dogbed), it renders the original and the three voiced files and hashes each with `knap-mcp structhash`.
3. **Row verdict.** A row passes when all four hashes are equal and each voiced doc differs from the original byte for byte. A template with no mock lines shows `no mock coverage` and does not fail; partial coverage (some tones only) or mock lines that no longer match the sample data (`stale mock`) do fail. `fields changed` counts the string values each tone rewrote (mild/spicy/feral).

Then two negative controls on verdict's `take`, which must change the hash in both targets:

- `markup`: the value gains `**boring**`.
- `newline-list`: the value gains a line break followed by `- `, which starts a list.

They show the hash catches layout drift and isn't just equal for everything.

## The structure hash

`src/structhash.zig`; CLI `knap-mcp structhash <doc_id|file>... [--target markdown|html] [--explain] [--strict]`; MCP tool `knap_structure_hash({doc_id})`. It drops every text leaf and hashes the remaining block and inline kind sequence with Wyhash. `--explain` prints the tokens, one per line, indented by depth. The format comes from `--target`, else the file or artifact extension, else sniffing.

- Markdown keeps frontmatter key names and list shapes (values are dropped, since a slug derives from the title), heading levels, paragraphs, lists and nesting, quotes, callouts with their `[!type]` and fold marker, table column count, alignment and cells per row (padding is ignored), code fences and their language, rules, footnote definitions, and the inline kinds: strong, emphasis, strikethrough, code, links, images, wikilinks (with or without a label), embeds, footnote refs, raw URLs, inline html, hard breaks. A `**` that pairs with nothing becomes a `delim:*` token, so even a stray marker moves the hash.
- HTML keeps tag names, nesting, attribute names, and the values of layout attributes (`class`, `type`, `colspan`, `rowspan`, `align`, `start`, `style`, ...). Text and text-derived values (`id` slugs, `alt`, `title`, `href`, `src`) are dropped.
- `--strict` also keeps link, image, wikilink and embed targets and footnote labels (markdown), and `href` and `src` (html).

## Coverage

Mock replies exist for verdict and apparatus only today, so release-notes and reading-note show `no mock coverage`. Lane C1 adds their mock lines; those rows then start to count with no change here. Hashes depend on the engine pins, so a pin bump can change every hash; the eval only compares hashes within one run.
