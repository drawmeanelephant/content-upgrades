# knap-mcp

AI can't do layout. So we don't let it.

One Zig binary: a stdio JSON-RPC MCP server **and** a CLI for judges
without an MCP client. The server is a dispatcher + orchestration layer —
rendering goes through `k4o` (markdown/oliver) and `dogbed` (html) as
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
The pins live in `../scripts/engines.sh`: k4o `bdfb838` (k4o main;
markdown or oliver) and dogbed `a7f8c27` (html). `make engines` builds a
missing pin into `~/.cache/knap-engines/`; the root `Makefile` exports
both paths for every target.

## CLI

```sh
knap-mcp templates                              # shipped templates + JSON shapes
knap-mcp validate verdict -d data/verdict.sample.json
knap-mcp render verdict -d data/verdict.sample.json --target markdown
knap-mcp render apparatus -d data/apparatus.sample.json --target html
knap-mcp repair verdict -d data/verdict.sample.json --backend mock
knap-mcp lint templates/verdict.knap
knap-mcp format-check doc-<id>                  # advisory structure lint on a stored doc
knap-mcp voice release-notes -d data/release-notes.sample.json --tone feral
knap-mcp structhash doc-<id>                    # layout skeleton hash (markdown|html)
knap-mcp verify-citation "<claim>" --evidence "<quote>"
knap-mcp boris-ask "point-in-time snapshots" --limit 3
knap-mcp boris-check "Does AcmeDB have managed backups?"
knap-mcp publish-check doc-<id>                 # stage into the boris site; exit 1 unless ok
knap-mcp density doc-<id>                       # formatting-density score (markdown)
knap-mcp ratchet release-notes -d data/release-notes.min.json --backend mock
knap-mcp ratchet-eval                           # ratchet climb table (eval/ratchet.json)
knap-mcp eval --corpus eval/seeds.json --backend mock   # convergence table
knap-mcp backends                               # backend availability
knap-mcp                                        # MCP stdio server
```

Exit 0 on success, 1 on any error — including a `render` or `validate`
that returns `{"ok":false}` (the JSON still goes to stdout).

## MCP tools

`knap_templates` · `knap_validate` · `knap_render` · `knap_repair` ·
`knap_lint` · `knap_format_check` · `knap_voice` · `knap_structure_hash` ·
`knap_verify_citation` · `boris_ask` · `boris_check` ·
`knap_publish_check` · `knap_density` · `knap_ratchet` — plus
`resources/list`/`resources/read` over `knap://templates/<id>` and
`knap://docs/<doc_id>` artifact handles.

`knap_format_check(doc_id)` is layer-2 validation: advisory structure lint
over a rendered markdown or oliver doc (html is refused) — skipped heading
levels, wall-of-text where a table belongs, unresolved/unused footnotes,
empty callouts, bare-URL count, heading/length ratio, unclosed fences,
list-heavy docs. Warnings only — it never blocks.

`knap_structure_hash(doc_id)` hashes a rendered doc's layout skeleton —
block and inline kinds with all text dropped — for markdown or html.
`strict` also keeps link targets and footnote labels. Equal hashes mean
the same layout; this is how the voice demo proves only the words changed.

`knap_verify_citation(claim, evidence)` is the advisory citation check:
`entails | neutral | contradicts | unknown`. `heuristic` (the default) is
verbatim match plus word overlap, not NLI; `decision` asks a model and
falls back to the heuristic. Advisory only, never on the render path.

`boris_ask(query)` / `boris_check(claim)` read the frozen boris site
artifact (`search-index.json`, `completion.json`) — no boris binary, no
live indexing. `ask` returns ranked snippets matching `ask.sh`; `check`
answers yes|no|unknown against the site's claim pages, with the matched
claim, polarity and term coverage (below 0.5 coverage: unknown).

`knap_publish_check(doc_id)` stages a rendered **markdown** doc into a
throwaway copy of the frozen boris site and runs `boris validate`
(`KNAP_BORIS_SITE`, `KNAP_BORIS_PATH`). Every wiki-link and embed must
resolve to a page — embeds are checked as links. Diagnostics map back to
line:column in the rendered doc; `ok` is false on any error.

`knap_density(doc_id)` is the deterministic formatting-density score
(density/1, 0–100) of a rendered markdown doc: per-signal breakdown plus
format_check penalties. Markdown only; no model call.

`knap_ratchet(template_id, data)` is the values-only ratchet: probe which
empty slot raises the density score most, ask the backend for one value,
keep it only if schema, markup and evidence checks pass and the markdown
score rises. A non-empty value and the template never change. Stops on
ceiling, plateau, stalled, `--max-iters` (default 6) or the call budget.
`ratchet-eval` runs the 11-case corpus in `eval/ratchet.json`.

## Voice

`knap_voice` rewrites the `voice: true` string values of a data object in
one tone (`--tone mild|spicy|feral`), one backend call per value; a
rewrite that fails the fact guard keeps the original, so the structure —
and the structure hash — is identical across tones. The contract
(eligibility walk, the never-rewritten list, the guard) is
`prompts/voice/README.md`. Prompts load from `KNAP_PROMPTS_DIR`, default
`../prompts` next to the templates dir.

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

`mock` (default): a canned patch table keyed on k4o main's diagnostics
(line and column) — unclosed `{% if %}`/`{% for %}`/`{{`/`{%`, unknown
filter, dangling `|`, unexpected text in or after a tag, stray or
mismatched block closers. Proves the loop with zero API access.
`spark`/`wonder`/`baseten`: OpenAI-compatible endpoints over curl, gated on
`MODEL_API_KEY`. `KNAP_BASETEN_URL` overrides the baseten endpoint.

## Eval harness

`make eval` runs both corpora through the repair loop: `eval/seeds.json`
(shipped templates mutated through the pinned error classes) and
`eval/seeds.2nap.json` (the same classes over the 2nap corpus). Output is
a per-seed and per-class convergence table plus a JSON report in the
artifact store. This is the slide-number factory — "backend fixes N/M
seeded breaks, mean iters X".

Mock convergence today: **12/22** on seeds.json (mean iters 1.25, exact
4/12, controls 3/3 clean) and **120/167** on seeds.2nap.json (mean iters
1.19, exact 58/115, controls 2/2 clean), with zero no-op seeds in either
corpus. The class table breaks convergence down by error class, so the
classes the mock cannot patch (unknown-tag, missing-value,
bad-filter-arg, unclosed-comment) read as honest NO rows, not bugs.
`exact` counts repairs byte-identical to the unbroken render — a patch
can converge without being exact, e.g. the mock deletes an unknown filter
rather than guessing the intended one. A "no-op seed" is a break the
pinned engine accepts without repair; both corpora assert none. Mock
patches are keyed on k4o main's diagnostic format, so these numbers move
with the pin.

## Layout

- `src/main.zig` — CLI command table (one row per subcommand) + test-import list
- `src/mcp.zig` — stdio JSON-RPC loop
- `src/tools.zig` — tool registry (one line per tool), dispatch, `tools/list`
- `src/tools/<name>.zig` — one handler per tool, shared by MCP and CLI
- `src/tools/common.zig` — shared handler helpers (args, data staging, diagnostics)
- `src/engine.zig` — subprocess dispatch + diagnostic parsing
- `src/backend.zig` — backend interface: mock patches + `complete()` for live models
- `src/repair.zig` — bounded repair loop
- `src/formatcheck.zig` — advisory structure lint (9 pinned rules)
- `src/density.zig` — formatting-density scorer (density/1)
- `src/structhash.zig` — layout-skeleton tokenizer + hash (markdown, html)
- `src/voice.zig` — voice rewrite logic (eligibility, guard, call assembly)
- `src/verifier.zig` — citation verifier slot (none | heuristic | decision)
- `src/ratchet.zig` — values-only ratchet loop + `ratchet-eval`
- `src/boris.zig` — boris site staging adapter for `knap_publish_check`
- `src/borisrag.zig` — frozen boris artifact: `boris_ask` + `boris_check`
- `src/eval.zig` — seeded-breakage harness
- `src/store.zig` — doc_id artifact handles + scratch files
- `src/ctx.zig` — shared context (paths, env, allocators)
- `templates/` — 4 shipped templates + `shapes/*.json` descriptors
- `data/` — sample, minimal (`.min.json`) and hallucinated data sets
- `prompts/voice/` — voice prompt contract, tone prompts, mock replies
- `eval/` — seeded-breakage corpora + lane harnesses (voice, boris, ratchet, verifier, density fixtures)
- `../scripts/engines.sh` — pinned k4o/dogbed builds (`make engines`)
- `../boris-site/` — frozen boris site: publish-check staging source, the boris_ask/check artifact
