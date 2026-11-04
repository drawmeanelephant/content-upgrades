# Submission capture: Meta Muse Spark open through Baseten

Credential-audited public artifacts from two genuine calls to
`meta-models/muse-spark-open-1026` on Baseten's direct API
(`https://inference.baseten.co/v1/chat/completions`), recorded 2026-11-04.
`sha256.json` pins every file here; re-hash to confirm nothing was edited
after capture.

## The draft take (`draft.*`)

`demo/baseten_take.py` asked the model for the `verdict` data object only —
the same schema `knap-mcp templates` prints. The model supplied JSON values;
the shipped human-authored template owns the layout.

| File | What it is |
|---|---|
| `draft.json` | The model's structured response, parsed to the verdict schema |
| `draft.response.json` | The raw chat-completion response |
| `draft.receipt.json` | Capture receipt: endpoint, elapsed seconds, usage, prompt and response hashes, `validation_ok`, `render_ok` |
| `draft.md` | `verdict` rendered from `draft.json` through the pinned engines |

## The upgrade take (`upgrade-*`)

`demo/record_upgrade.py` ran one bounded `ratchet` iteration on the same
draft: `--max-iters 1`, capped at two candidate-value calls, no retry run.
The receipt is `upgrade.receipt.json`:

- **2 calls, 1 accepted step.** Spark declined the `apparatus_page` slot
  (probe gain 10.0, no value kept), then supplied a `receipts[+]` row that
  passed schema, markup, and evidence checks and raised the score.
- **density/3: 24.7 → 34.4** (ceiling 34.8), stopping on `max_iterations`.
  `upgrade-before.md` and `upgrade-after.md` render both states; the scorer
  was re-run on the rendered files during capture and matched the reported
  scores.
- **Existing values and the template did not change.** `before.json`
  re-derives the seed from `draft.json`; the capture fails if any
  pre-existing value differs or the template hash
  (`b60714cd…af6be2`) moves.
- **`credential_in_public_output: false`.** Every file was checked against
  the capture credential (full value plus edge substrings) before being
  written or frozen.

| File | What it is |
|---|---|
| `upgrade-before.json` / `upgrade-before.md` | Seed data and render before the loop |
| `upgrade-after.json` / `upgrade-after.md` | Data and render after the accepted step |
| `upgrade.result.json` | The ratchet tool's own result: steps, gains, stop reason |
| `upgrade.receipt.json` | The capture's receipt: budgets, hashes, scope note |

## Scope

One bounded formatting-density example, not a model-quality benchmark. A
recorded take does not claim every model call succeeds — the declined slot
is part of the artifact. `density/3` measures formatting density, not
factual accuracy or writing quality.

Re-run the control path offline:

```sh
eval "$(scripts/engines.sh env)"
python3 demo/record_upgrade.py --backend mock \
	--data demo/frozen-submission/draft.json --output "$(mktemp -d)/capture"
```
