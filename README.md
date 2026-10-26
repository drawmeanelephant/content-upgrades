# Content Upgrades

AI writes markdown in one flat barf: wall-paragraph, header, wall-paragraph, voice ironed out. This fixes it with a loop, not a prompt. Cheap models draft and fill the values; a deterministic scorer (`density/1`, `knap-mcp/src/density.zig` — never a model call) scores the result for formatting density (callouts, footnotes, tables, styled runs, real apparatus), and the loop ratchets until the score climbs.

Built for the [Cerebral Valley Meta AI Developer Hackathon](https://cerebralvalley.ai/e/meta-ai-developer-hackathon).

## Components

- `knap-mcp/` — Zig MCP server + CLI: 4 shipped templates (`verdict`, `apparatus`, `release-notes`, `reading-note`), engine dispatch (k4o/dogbed), bounded repair loop, seeded-breakage eval harness, voice tone presets (`mild`/`spicy`/`feral`, see `knap-mcp/prompts/voice/`). See `knap-mcp/README.md`.
- `docs/` — SPEC.md, GAMEPLAN.md, the density-eval notes.
- `corpus/render.json` — vendored 188-case language-independent knap fixture set (MIT, upstream Obsidian knap).

## License

MIT — see [LICENSE](LICENSE).
