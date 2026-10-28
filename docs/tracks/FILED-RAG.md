# FILED-RAG: `boris_ask` / `boris_check` over filed publish exports

Status: done, scoped to `ask` per the issue's exit clause (#258).

## What landed

| Path | Change |
|---|---|
| `knap-mcp/src/borisrag.zig` | Multi-shape artifact resolution, filed `rag/` working-pack parser, `Shape` on `Artifact`, `"artifact"` field in both JSON writers, no-claim-pages reason |
| `knap-mcp/src/tools/boris_ask.zig` | Pass `art.shape` to `writeAskJson`; description mentions both shapes |
| `knap-mcp/src/tools/boris_check.zig` | Pass `art.shape` to `writeCheckJson` (report field only); description notes filed always answers unknown |

Shared one-liner: `KNAP_BORIS_ARTIFACT` row in the `usage_tail` Environment
table in `main.zig`.

## Resolution order

`KNAP_BORIS_ARTIFACT` (points directly at an artifact dir) beats site
probing. Otherwise under `KNAP_BORIS_SITE` (else the shipped boris-site):
`artifact/` then `publish/`. At each root the frozen pair
(`search-index.json` + `completion.json`) wins over `rag/manifest.json`.
A signature file commits to its shape — a present-but-broken export is an
error, not a skip. Neither shape anywhere fails with
`no readable boris artifact; probed: <all paths>`.

## The filed mapping

- `rag/manifest.json` (`format: "boris-rag"`) supplies `upload_files`
  order; packs parse at line-start `<!-- boris-rag-doc:` markers only (the
  pack header names the marker inside backticks — mid-line matches are not
  doc starts).
- Each marked block is a verbatim boris source file: frontmatter gives
  `id`/`title`, the body splits into `Section`s at ATX headings (fenced
  code → `code`, prose → `text`, pre-heading preamble → level 0). Entity
  id = frontmatter `id`, else marker `id` minus `content/`.
- `ir/completion.json` (same `boris-completion-index` schema as frozen)
  supplies entities when the publish run exported it; optional.

`ask` then runs the unchanged ranker, so scores/snippets work the same —
verified on `~/dev/filed.fyi` with a full `publish/` build:
`boris-ask "Bin 8C"` ranks the Bin 8C lorelog/limerick records on top.

## `check` is scoped out, not faked

Filed entities carry zero `claim`/`supported`/`refuted`/`unverified` tags
and only `relates_to` edges — no checkable claims surface (measured, see
issue trail). `boris_check` over the filed shape answers `unknown` with
`matched: null` and an explicit "no claim-tagged pages" reason. The same
early return covers a frozen artifact with no claim pages
("the artifact has no claim pages to check against").

## Notes for other lanes

- Frozen output gains one additive field: `"artifact":"frozen"`. Hit
  objects, scores, order, snippets, verdicts are byte-identical — the B3
  oracle gate passes 25/25 ask + 14/14 check.
- `context/` is not read: it duplicates `rag/`'s content for this lane's
  purposes. Detection keys on `rag/manifest.json` alone, so a rag-only
  export still works.
- If a future lane wants `check` over filed, the surface needed is
  claim-tagged entities with verdict tags + `cites` — none exists today.
