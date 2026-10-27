# Knap contest — research + ideas

## What knap is

- Template language: `data → Markdown`. By kepano (Steph Ango / Obsidian). MIT.
- Repo: https://github.com/obsidianmd/knap — cloned here at `knap/` (v0.6.0, ~630★, created Aug 2026).
- Powers Obsidian Web Clipper templates + Obsidian Importer.
- Arch: tokenizer → parser → AST → renderer. No eval/JS. Hosts control data + filters + resolvers.
- Language: `{{ var }}` (dot/bracket paths, names w/ spaces), `{% if/elseif/else %}`, `{% for %}` w/ `loop.*`, `{% set %}`, `{# #}` comments, `??` fallback, `contains`/`and`/`or`/`not`, ~60 filters (case, markdown fmt, collections, yaml, html, date, math). 0.6.0 made filter chains preserve typed values.
- CLI: `knap render` (file/inline/stdin + `--set`), `knap validate`, `knap batch` (CSV/JSON/folders), offline help. Node 20+, ESM+CJS.
- API: `createEngine`, custom sync/async filters, resolvers, render limits (size/output/ops/nesting), `allowRegex:false`.
- Security: scheme blocklist (javascript:/vbscript:/data:), own-prop resolution only, no setters, ReDoS opt-out, symlink-safe batch writes.
- Editors: VS Code/Cursor VSIX, Sublime pkg, Prism/CodeMirror/highlight.js adapters.
- Website: Astro + playground on Cloudflare.
- Open issues (contest fodder): #16 concat variables, #15 custom blocks via API, #10 loop a root array.

## The killer asset: compat/fixtures/render.json

- 188 language-independent cases, `format_version: 1`, `standard` preset.
- Explicitly designed for non-TS implementations — "no JavaScript runtime required."
- Prescribes report format: pass / fail / unsupported, byte-exact output incl. whitespace, ordered error+warning codes.
- Pin repo commit + format version. Hidden-case extension is easy via `tests/fixtures/portable-render.ts`.
- This is a ready-made scoring harness. It's exactly what k4o already does with oracle-diffing.

## Existing pieces

- k4o (~/dev/k4o): clean-room Zig knap subset → Textile/CommonMark/GFM. verify.sh gate, red-green mutants, `tools/differential` oracle harness. = proof the contest model works.
- dogbed (~/dev/dogbed): `knap + JSON → k4o → Textile → oliver → HTML`, one static binary. = flagship "application track" example.
- Constraint: no container runtimes on this machine — judging must be CLI-contract + native toolchains (or remote CI).

## Contest formats

### A. Engine reimplementation ("write knap in X")
- Standard CLI contract: `render template.knap --data data.json` → stdout bytes, stderr diagnostics, exit codes. Language-agnostic, auto-judgeable.
- Scoring: % of render.json passed + hidden held-out cases + property-based fuzz diff vs reference oracle + crash/robustness battery.
- Divisions: clean-room (docs+oracle only, k4o rules) vs open. WASM-wrapping reference knap = separate division or banned in engine track (trivial 100%).
- Optional constraints for style points: single-file, stdlib-only, binary-size cap, embedded target.

### B. Tracks beyond engines
- Tooling: linter/formatter, LSP, syntax grammars, template debugger, prettier-for-knap.
- Applications: static site gen, report pipelines, batch renderers (dogbed-style), integrations (Hugo/Jekyll/obsidian-plugin).
- Filter/spec design: propose + implement new filters; judged on utility + doc quality. Open issues #10/#15/#16 are seeded feature prompts.
- Template golf / showcase: best real-world template pack (like knap-templates repo).

### C. Judging/scoring specifics
- Correctness 50%: public 188 fixtures qualify; hidden corpus finals (authored same way, never published).
- Robustness 20%: malformed templates → ordered diag codes, empty stdout on error, no partial emit, limits trip correctly.
- Security 15%: proto-pollution keys, javascript: links, ReDoS args, symlink batch writes.
- Performance 15%: bench/ corpus (tokenize/parse/render/engine benches), cold start, memory.
- Report format per fixtures README: separate pass/fail/unsupported; byte-exact incl. trailing whitespace; ordered diagnostics.

### D. Structure
- Submission: git repo, `Makefile`/build script producing a binary conforming to CLI contract. Judge harness = fork of k4o `tools/differential`.
- Qualifier (public fixtures, 1-2 wks) → finals (hidden fixtures + fuzz round).
- Anti-overfit: regenerate hidden cases at finals time; fuzz seeds from bench + clipper fixtures.
- Reference impl available to judges only, via pinned npm version.

## Name ideas (knapping = shaping stone tools)

- **Knap-off** / **The Knappathon** / **Flint & Steel** / **Arrowhead** / **Cairn** (already a site motif: `CairnHeadline.astro`)

## Open questions for you

1. Engine-implementations only, or multi-track?
2. Clean-room requirement, or open?
3. Solo or teams? Timeframe?
4. Who judges/prizes — personal, Cognition, or community?
5. Is k4o a reference entry, an example, or barred as organizer's project?
