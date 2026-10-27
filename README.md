# Content Upgrades

AI writes markdown in one flat barf: wall-paragraph, header, wall-paragraph, voice ironed out. `knap-mcp` fixes it with a loop, not a prompt. A model drafts and fills JSON *values*; the formatting — callouts, footnotes, tables, styled runs, a citations apparatus — lives in shipped, human-authored templates. A deterministic scorer (`density/2`, never a model call) scores the result, and a ratchet loop fills the highest-value empty slot until the score climbs. Maximum formatting, zero formatting risk: the model never writes markup, so it can't break it.

## Install

- Zig 0.17.0
- `jq` for `make demo`; `boris` on PATH for the publish-check beat (optional — it's skipped without it)

```sh
make           # -> knap-mcp/zig-out/bin/knap-mcp
make engines   # pinned k4o + dogbed into ~/.cache/knap-engines
make install   # -> ~/.local/bin/knap-mcp (PREFIX=/usr/local to relocate)
make test
```

Put `~/.local/bin` on `PATH` for the bare `knap-mcp` commands below, or call `knap-mcp/zig-out/bin/knap-mcp` directly. An installed binary still resolves templates and its artifact store from the cwd — point `KNAP_TEMPLATES_DIR` at `<repo>/knap-mcp/templates` and `KNAP_MCP_HOME` where you want artifacts when running it elsewhere (install-aware defaults are tracked in #176).

Engine pins live in `scripts/engines.sh` (k4o `aeba163`, dogbed `d96b125`). The Makefile exports `KNAP_K4O_PATH` / `KNAP_DOGBED_PATH` for every `make` target; for direct CLI runs outside make, `eval "$(scripts/engines.sh env)"`.

## Quickstart — no accounts needed

```sh
make demo
```

Runs the whole pipeline end-to-end on the built-in `mock` backend — draft data, seeded repair, render, format check, density ratchet, publish check, voice tones, three output targets — and leaves the transcript and artifacts in `demo/out/demo/`. Takes a few seconds.

Then drive it yourself from `knap-mcp/`:

```sh
knap-mcp templates                                       # shipped templates + their JSON shapes
knap-mcp render verdict -d data/verdict.sample.json      # -> {"ok":true,"doc_id":...}
knap-mcp ratchet release-notes -d data/release-notes.min.json --backend mock
# converges in 5 iterations: density/2 score 39.2 -> 82.5, values only — the template never changes
```

## Model providers — use what you already have

No paid API is required. `mock` is the default backend and runs the full loop offline; everything above works with zero accounts. For a real model, point `acp` or `compat` at an agent or endpoint you already have:

| Path | Needs | How |
|---|---|---|
| `mock` (default) | nothing | canned patches; proves the whole loop offline |
| ACP agent | `devin` CLI (free tier), `gemini` CLI (Google account), `codex-acp` (ChatGPT account), or `opencode` | `KNAP_ACP_AGENT='devin acp --model swe-2-medium' knap-mcp ratchet release-notes -d data/release-notes.min.json --backend acp` |
| ollama | local `ollama` + a pulled model | `OLLAMA_MODEL=<model> make live P=ollama`, or `KNAP_COMPAT_URL=http://127.0.0.1:11434/v1/chat/completions KNAP_COMPAT_MODEL=<model>` + `--backend compat` |
| `compat` | any OpenAI-compatible endpoint | `KNAP_COMPAT_URL` + `KNAP_COMPAT_MODEL` (+ optional `KNAP_COMPAT_KEY`) |
| `spark` / `wonder` / `baseten` | `MODEL_API_KEY` | Meta API endpoints |

`knap-mcp backends` shows what each resolves to; `backends --probe` handshakes the live ones. `scripts/live.sh --list` lists the bundled provider profiles and their readiness, and `make live P=<profile>` smoke-tests a profile before spending eval calls on it — `make live P=fake` needs nothing at all.

## Components

- `knap-mcp/` — one Zig binary: stdio MCP server **and** CLI. 4 shipped templates (`verdict`, `apparatus`, `release-notes`, `reading-note`), k4o/dogbed engine dispatch, bounded repair loop, values-only density ratchet, voice tone presets (`mild`/`spicy`/`feral`), seeded-breakage eval harness. Command and tool reference: `knap-mcp/README.md`.
- `docs/SPEC.md` — tool contracts and the repair-loop state machine.
- `demo/` — the scripted end-to-end run behind `make demo`; reproducible transcript in `demo/out/demo/`.
- `corpus/render.json` — vendored 188-case language-independent knap fixture set (MIT, upstream Obsidian knap).

## License

MIT — see [LICENSE](LICENSE).
