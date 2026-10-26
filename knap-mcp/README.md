# knap-mcp

AI can't do layout. So we don't let it.

One Zig binary: a stdio JSON-RPC MCP server **and** a CLI for judges
without an MCP client. The server is a dispatcher + orchestration layer —
rendering goes through `k4o` (markdown/gfm/textile) and `dogbed` (html) as
external binaries. The model writes JSON values and repair patches only;
templates are shipped, server-side, human-authored. Nothing ships
unverified.

## Build

Requires Zig 0.17.0.

```sh
zig build          # -> zig-out/bin/knap-mcp
zig build test
```

Engines resolve from `KNAP_K4O_PATH` / `KNAP_DOGBED_PATH`, else `PATH`.

## CLI

```sh
knap-mcp templates                              # shipped templates + JSON shapes
knap-mcp validate verdict -d data/verdict.sample.json
knap-mcp render verdict -d data/verdict.sample.json --target markdown
knap-mcp render apparatus -d data/apparatus.sample.json --target html
knap-mcp repair verdict -d data/verdict.sample.json --backend mock
knap-mcp lint templates/verdict.knap
knap-mcp format-check doc-<id>                  # advisory structure lint on a stored doc
knap-mcp eval --corpus eval/seeds.json --backend mock   # convergence table
knap-mcp backends                               # backend availability
knap-mcp                                        # MCP stdio server
```

## MCP tools

`knap_templates` · `knap_validate` · `knap_render` · `knap_repair` ·
`knap_lint` · `knap_format_check` — plus `resources/list`/`resources/read`
over `knap://templates/<id>` and `knap://docs/<doc_id>` artifact handles.

`knap_format_check(doc_id)` is layer-2 validation: advisory structure lint
over a rendered doc (skipped heading levels, wall-of-text where a table
belongs, unresolved/unused footnotes, empty callouts, bare-URL count,
heading/length ratio, unclosed fences, list-heavy docs). Warnings only —
it never blocks.

## Repair loop

```
draft -> render -> [ok] -> done
                -> [diag] -> region(diag.line +/- N, or ->EOF for unclosed)
                         -> backend patch -> re-render -> iter<4 ? loop
                                                       : best-effort+diags
```

Patch-per-diagnostic, first error only; regions are surgical slices. Max 4
iterations; non-convergence returns diagnostics — a feature, not a failure.

## Backends

`mock` (default): canned patch table — unclosed if/for, unknown filter,
dangling `|`, unclosed `{{`. Proves the loop with zero API access.
`spark`/`wonder`/`baseten`: OpenAI-compatible endpoints over curl, gated on
`MODEL_API_KEY`. `KNAP_BASETEN_URL` overrides the baseten endpoint.

## Eval harness

`eval/seeds.json` mutates shipped templates through pinned error classes;
each seed runs the repair loop; output is a markdown convergence table plus
a JSON report in the artifact store. This is the slide-number factory —
"backend fixes N/M seeded breaks, mean iters X". The corpus includes
referential-apparatus breaks (unclosed sources loop, bad `wikilink` arg,
missing `yaml_property` arg) that the mock backend cannot patch — their
NO rows are the honest non-convergence signal, not a bug.

## Layout

- `src/main.zig` — CLI command table (one row per subcommand) + test-import list
- `src/mcp.zig` — stdio JSON-RPC loop
- `src/tools.zig` — tool registry (one line per tool), dispatch, `tools/list`
- `src/tools/<name>.zig` — one handler per tool, shared by MCP and CLI
- `src/tools/common.zig` — shared handler helpers (args, data staging, diagnostics)
- `src/engine.zig` — subprocess dispatch + diagnostic parsing
- `src/backend.zig` — backend interface: mock patches + `complete()` for live models
- `src/repair.zig` — bounded loop
- `src/formatcheck.zig` — advisory structure lint (8 pinned rules)
- `src/eval.zig` — seeded-breakage harness
- `src/store.zig` — doc_id artifact handles + scratch files
- `src/ctx.zig` — shared context (paths, env, allocators)
- `templates/` — shipped templates + `shapes/*.json` descriptors
- `eval/seeds.json` — seeded-breakage corpus
- `../scripts/engines.sh` — pinned k4o/dogbed builds (`make engines`)
