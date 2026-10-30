# LIVE-BASETEN: Baseten smoke + evals (issue #220)

First live run of the `baseten` backend. The kind was wired since the
harness landed but had never answered a real call — `MODEL_API_KEY` was
pending and two defaults were wrong or unconfirmed.

## What changed

- **`defaultEndpoint(.baseten).url`:**
  `https://api.baseten.co/v1/chat/completions` →
  `https://inference.baseten.co/v1/chat/completions`. Baseten's Model
  APIs serve chat completions on the `inference` host
  (docs.baseten.co/reference/inference-api); the old `api` host 404s
  that path. `models_url` derives to
  `https://inference.baseten.co/v1/models` automatically.
- **Endpoint test** (`backend.zig`): the baseten assertions now pin the
  URL and the derived models URL, not just the model.
- **Default model kept:** `meta-models/muse-spark-open-1026`. The issue
  guessed this id was dead — it isn't. `GET /v1/models` serves it
  (listed as "[HACKATHON] Muse Spark Open"), and it is the *only* model
  the sponsor key can call: the key is hackathon-scoped, and every other
  served id (`meta-models/muse-spark-open`, `openai/gpt-oss-120b`,
  `deepseek-ai/DeepSeek-V4.1-Flash`, …) answers
  `403 {"error":"please check the api-key you provided"}`. A normal
  paid Baseten key should point `KNAP_BASETEN_MODEL` at the public
  `meta-models/muse-spark-open` instead.
- `scripts/providers.sh` `baseten` arm: unchanged — the label
  `Muse Spark open (Baseten)` still names the model.

## Env

```sh
export MODEL_API_KEY="$BASETEN_API_KEY"
make live P=baseten          # no KNAP_BASETEN_URL/_MODEL needed
```

`temperature: 0` is accepted — no `KNAP_BASETEN_TEMPERATURE=omit`.
Responses carry `reasoning_content`; usage is metered and the smoke
counts `reasoning_tokens` separately.

## Smoke (defaults, no overrides)

```
backend: baseten   model: meta-models/muse-spark-open-1026   effort: -   served: yes
```

| row | ok | ms | finish | answer B | reasoning B | shape |
|---|---|--:|---|--:|--:|---|
| repair | yes | 1652 | stop | 17 | 1247 | exact |
| voice | yes | 1567 | stop | 16 | 1710 | exact |
| verify | yes | 1847 | stop | 17 | 671 | exact |
| judge | yes | 998 | stop | 16 | 724 | exact |
| enrich | yes | 1019 | stop | 17 | 707 | exact |
| repair-patch | yes | 2444 | - | 49 | - | exact |

smoke: 6/6 ok, mean ~1.6 s/call.

## Results row (LIVE.md table columns)

| profile | model (agent-reported) | smoke | repair `seeds.json` | ratchet `ratchet.live.json` | voice (verdict) |
|---|---|---|---|---|---|
| baseten | `meta-models/muse-spark-open-1026` | 6/6 ok, 1.6 s/call | 22/22 conv, 1.05 iters, 9/22 exact; **2nap 165/167 conv (99%), 1.02 iters, 107/157 exact** | 8/9 ok (`fixture-footnotes` accepted 1 < 2; `reading-note-min` +41.1, `apparatus-min` +25.2, `iteration-cap` +34.8) | 2/2 layout-identical (`mild` 7/8, `feral` 5/8, 3 rejected) |

Raw outputs, `provenance.json` and `summary.txt` are in
`knap-mcp/eval/results/live/baseten/` (engines k4o `aeba163` /
dogbed `d96b125`).

## Caveats

- **Key scope.** The sponsor key authenticates (GET `/v1/models` → 200,
  anonymous → 401) but is restricted to `muse-spark-open-1026`. Any
  other model 403s. If the key is rotated to a full-access key,
  consider switching the default model to the public
  `meta-models/muse-spark-open`.
- **2nap misses.** `seeds.2nap.json` converged 165/167 (99%). The two
  misses are `var-bracket-index/unclosed-output` and
  `var-missing/unclosed-output` — each left 1 residual diag after one
  iteration. Both are `unclosed-output` `remove` breaks.
- **Repair re-run noise.** The `--full` pass re-ran `seeds.json` too;
  exact count moved 8/22 → 9/22 run to run (live models are not
  deterministic). Committed files are the latest run.
- **Spend.** Full suite ≈ 340 calls (smoke 6, repair 23+171, ratchet
  32 + probe renders, voice 8 + renders), ~400k tokens on the -1026
  pricing — low single-digit dollars.
