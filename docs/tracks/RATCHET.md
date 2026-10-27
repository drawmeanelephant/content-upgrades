# RATCHET lane notes

## #82 — `evidence:"boris"` (this PR)

- `ratchet.Options.evidence: ratchet.Evidence` (`data` | `boris`, default
  `data`). `run()` picks the pool once, at `Run` construction: `data` keeps
  `dataEvidence` (`data.sources[*]` quote/text/string); `boris` loads the
  artifact via `borisrag.load` (same path as `tools/boris_ask.zig` —
  `KNAP_BORIS_SITE`, else `<templates>/../../boris-site`) and takes
  `borisrag.ask` snippets for `subject ?? title`, `limit = 5`,
  `claims_only = false`. Missing subject and title fails the run before
  any render.
- `knap_ratchet` schema enum is now `["data","boris"]`; anything else is a
  `ToolFailed` naming both valid values.
- `--evidence` was already in `tool_flags` (verify-citation added it), so
  `knap-mcp ratchet <id> -d f.json --evidence boris` needed no flag work;
  the one shared `usage_tail` line now covers both meanings.
- The boris pool feeds both the enrich slice (`EVIDENCE:` in
  `buildSlice`) and the verifier gate (`checkEvidence`), unchanged.
- Done-when test: `ratchet.zig` test "boris evidence" — a fixture
  artifact's snippet is accepted verbatim on an evidence-gated slot and a
  paraphrase is rejected by `checkEvidence` (heuristic).
- No ratchet-eval corpus support for `evidence` (kept the diff tight —
  other lanes own the eval region); the unit test carries the gate.

Gates: `make test` green; `KNAP_MCP_HOME=$(mktemp -d) make eval` green
(120/167 converged, same as baseline). Smoke:
`ratchet reading-note -d data/reading-note.min.json --evidence boris`
runs to `max_iterations` with hits on "The Machine Stops".
