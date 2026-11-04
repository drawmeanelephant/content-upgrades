# SUBMISSION: public claims and their evidence

Maps each claim in `README.md` to the command or recorded artifact that
supports it. Recorded takes are examples with receipts, not benchmarks.

## Claims → evidence

| Claim | Evidence |
|---|---|
| The model fills JSON values; human-authored templates own layout | `demo/frozen-submission/draft.*`: the raw Baseten response is data only, and `draft.md` renders it through the shipped `verdict` template. `docs/SPEC.md` pins the contract. |
| Accepted ratchet steps improve the deterministic `density/3` score | `demo/frozen-submission/upgrade.result.json`: the `receipts[+]` step was kept only after its rendered score rose (24.7 → 34.4); the declined `apparatus_page` step kept nothing. `upgrade.receipt.json` records `existing_values_unchanged` and `template_unchanged` with hashes. |
| Live calls go to Meta models through Baseten | `draft.receipt.json` and `upgrade.receipt.json` name `meta-models/muse-spark-open-1026` on `inference.baseten.co` with usage and timestamps. |
| Evidence-marked fields pass the configured verifier | `ratchet.zig` `dataEvidence` reads bare strings, flat `quote`/`text`, and the shipped `sources[*].quotes[*].text` shape — regression-tested in `ratchet.test.data evidence reads nested source quotes` and `… keeps legacy sources`. The default `heuristic` verifier is advisory, not a fact-checker. |
| Voice guards constrain markup and protect named tokens | `demo/frozen/06-structhash.txt` plus the `mild`/`feral` takes: same layout skeleton across tones. Guard contract: `knap-mcp/prompts/voice/README.md`. |
| Publication checks resolve references against a site graph | Demo beat 5 (`05-boris-catch.tape` / `make demo` beat 5) against `boris-site/`'s frozen graph. |
| The whole pipeline runs without credentials | `make demo` and `make eval` use the `mock` backend and recorded takes only. |

## Gate output (2026-11-04, this checkout)

- `make test`: **329/329 passed**, including the two new `dataEvidence`
  regression tests.
- `KNAP_MCP_HOME=$(mktemp -d) make eval`: converged 120/167 seeded breaks,
  mean 1.19 iterations, **controls 2/2 clean**, 0 no-op seeds.
- `make demo`: all beats ok (cold open → ask → repair → render/format/density
  → ratchet → publish check → mild vs feral → multi-target → numbers card).
- Bounded live upgrade capture (`demo/record_upgrade.py --backend baseten`):
  2 calls, 1 accepted step, credential audit clean — frozen under
  `demo/frozen-submission/` with SHA-256 pins.

Gate transcripts are regenerated artifacts (`demo/out/` is gitignored);
re-run the commands above to reproduce them.

## Honest limits kept in the README

- `density/3` is formatting density, not quality or truth.
- The `heuristic` verifier is not a general semantic fact-checker.
- Voice guards constrain structure, not the meaning of rewritten prose.
- `publish_check` resolves links; it does not vouch for their claims.
- Recorded takes show the calls that happened, not a success rate.
