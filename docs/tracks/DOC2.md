# DOC2: knap-mcp/README.md catches up with wave 1

Status: done. Lane files: `knap-mcp/README.md`, this note. Nothing else
touched.

## What changed

- Intro: k4o renders `markdown | oliver` (was `markdown/gfm/textile`).
- Build: the engine paragraph now names the pins in
  `../scripts/engines.sh` (k4o `bdfb838`, dogbed `a7f8c27`) and `make
  engines`.
- CLI block: one row per new subcommand — `voice`, `structhash`,
  `verify-citation`, `boris-ask`, `boris-check`, `publish-check`,
  `density`, `ratchet`, `ratchet-eval`. New exit-code line: a `render` or
  `validate` that returns `{"ok":false}` exits 1, JSON still on stdout
  (`main.zig` `runTool`).
- MCP tools: the list is all 14 registered tools (`tools.zig` `all`).
  One short paragraph each for `knap_structure_hash`,
  `knap_verify_citation`, `boris_ask`/`boris_check`, `knap_publish_check`,
  `knap_density`, `knap_ratchet`, in the existing `knap_format_check`
  style. `knap_voice` detail lives in a new short `## Voice` section that
  points at `prompts/voice/README.md` as the contract and names
  `KNAP_PROMPTS_DIR` (default `../prompts` next to the templates dir).
- Backends: the mock description now says the patch table is keyed on k4o
  main's diagnostics (line + column) and lists today's rule classes.
- Eval: `make eval` runs both corpora; measured mock numbers are 12/22
  (exact 4/12, mean iters 1.25, controls 3/3) on seeds.json and 120/167
  (exact 58/115, mean iters 1.19, controls 2/2) on seeds.2nap.json, zero
  no-op seeds. One sentence each on the class table, `exact`
  (byte-identical repair), and no-op seeds.
- Layout: added `density.zig`, `structhash.zig`, `voice.zig`,
  `verifier.zig`, `ratchet.zig`, `boris.zig`, `borisrag.zig`, `data/`,
  `prompts/voice/`, `eval/` (corpora + lane harnesses), `../boris-site/`.
  Templates now number 4.

## Where the code won over the lane notes

- **seeds.json `exact` is 4/12, mean iters 1.25** — P1's note says 3/12 /
  1.17. Measured today (`knap-mcp eval --corpus eval/seeds.json --backend
  mock`): `converged 12/22 breaks   mean iters 1.25   exact 4/12   no-op
  seeds 0   controls 3/3 clean`. T2's template rewrite moved it after
  P1's table was written. The README prints today's numbers.
- **dogbed pin is `a7f8c27`** (`scripts/engines.sh`), superseding the
  `d7ffaba` T2's note measured against. P1's note confirms the bump.
- **formatcheck has 9 rules**, not the 8 the old README claimed
  (empty-callout, skipped-heading, unresolved-footnote, unused-footnote,
  raw-url-count, unclosed-fence, heading-ratio, list-heavy, wall-of-text).
- **`knap_publish_check` rejects non-`.md` docs.** B2's note says "html
  and textile" are rejected; textile no longer exists as a target, and
  oliver renders store as `.md` so they are accepted — correct anyway,
  since oliver is CommonMark.
- **Tool names are `boris_ask` / `boris_check`** (no `knap_` prefix).
  Documented as registered.
- **`knap_format_check` accepts oliver** (`.md`) and refuses html — the
  README now says so instead of "a rendered doc".

## Gate

```text
$ make test                       -> exit 0
$ KNAP_MCP_HOME=$(mktemp -d) make eval
  seeds.json:     converged 12/22   mean iters 1.25   exact 4/12    no-op 0   controls 3/3 clean
  seeds.2nap.json: converged 120/167  mean iters 1.19   exact 58/115  no-op 0   controls 2/2 clean
```

Every command in the CLI block was run against the built binary
(`zig-out/bin/knap-mcp --help` agrees): render, validate (exit 0),
boris-ask, boris-check, verify-citation, structhash, density (verdict
77.5), voice --tone mild --backend mock (15 fields changed), ratchet
release-notes --backend mock (ceiling, 44.5 -> 71.8), ratchet-eval (11/11
expectations met). publish-check needs a boris binary; its row matches
`--help`.
