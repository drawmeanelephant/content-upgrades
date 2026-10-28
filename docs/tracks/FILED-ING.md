# FILED-ING lane notes — #251: ingest existing .md docs into the artifact pipeline

## What landed

| Path | What |
|---|---|
| `knap-mcp/src/tools/ingest.zig` | New. `knap_ingest` tool (`path`/`paths`/`force`) + `knap-mcp ingest <file>... [--force]` CLI; stores bytes verbatim via `store.put`, one `{"ok":true,"doc_id":...}` line per file |
| `knap-mcp/src/tools/common.zig` | Shared `<doc_id|file>` resolution: `resolveDoc` (file wins over doc_id), `docExtForPath` (.md/.markdown → `md`, else honest ext, none → `txt`), `docIdOrStage` (stage file → doc_id passthrough), `max_doc_bytes` |
| `knap-mcp/src/tools/density.zig` | `cmd` now uses `common.resolveDoc` (was inline `readFileAlloc`) |
| `knap-mcp/src/tools/structure_hash.zig` | `cli` uses `resolveDoc`; `file_path` replaces the second `Dir.access` probe for format detection |
| `knap-mcp/src/tools/format_check.zig` | New `cli`: file → stage → dispatch; doc_id unchanged |
| `knap-mcp/src/tools/publish_check.zig` | `cli` stages a file arg via `docIdOrStage` before dispatch |
| `knap-mcp/src/main.zig` | `ingest` row (custom), `format-check` row now `.custom` accepting `<doc_id|file>`, `publish-check` usage, `--force` help line, test-import |
| `knap-mcp/src/tools.zig` | Registry line for `knap_ingest` |

## Decisions

- **Byte-preserving.** `ingest` is a `store.put` of the raw file bytes —
  no normalization, no frontmatter touch. A SHA-256 equality test pins
  this. `resources/list`/`resources/read` see ingested docs exactly like
  renders (same `doc-<ns>-<n>.md` naming), no mcp.zig changes needed.
- **Extension policy.** `.md`/`.markdown` (any case) ingest as `md`.
  Anything else — including no extension — needs `--force`, and keeps
  its honest extension in the store so md-only tools still refuse a
  forced `.html`/`.txt` with a clear message.
- **Staging for format-check/publish-check** derives the extension from
  the filename the same way, so `format-check page.html` gets the
  tool's existing ".html" refusal rather than garbage warnings.
- **`knap_ingest` schema** exposes both `path` (single) and `paths`
  (array); both fill the same list, order preserved.
- **Tool stays doc_id-only on MCP.** File-path parity is CLI-side, same
  as density/structhash — an MCP client with a path ingests first.

## Verified

- `ingest` → doc_id; `format-check`/`publish-check`/`density`/`structhash`
  all run on it; byte-identical round-trip (`cmp`).
- `format-check <file>` and `publish-check <file>` work with no ingest
  step (publish-check staged a doc and ran `boris validate` ~31 ms).
- `tools/list` shows `knap_ingest`; `tools/call` + `resources/list` +
  `resources/read` over `knap://docs/` all see the ingested doc.

## What other lanes must know

- FILED-PUB (#252): `publish-check <file>` stages under a synthetic
  `doc-<ns>-<n>` name, so `staged_as` is the doc_id, not the source
  basename — slug/canonical-ID handling is that lane's job.
- FILED-TPL (#256) / FILED-VOICE (#257): ingest gives you doc_ids for
  existing records; nothing here derives titles or slugs from them.
