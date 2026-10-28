# LIVE: provider plug-in harness

Issue #153. Testing a provider is now a matter of pointing at it. The work
no longer waits on a key: every suite runs today on the providers we have,
and a sponsor key becomes one command.

```sh
scripts/live.sh --list                               # profiles + readiness
make live P=devin-wonder SUITE=all                   # smoke, repair, ratchet, voice
make live P="spark wonder baseten" SUITE=all         # the whole #89/#90/#91 job, once MODEL_API_KEY exists
make live P=fake                                     # credential-free self-test
```

## What landed

- **`knap-mcp smoke [--backend k]`** (`src/smoke.zig`) runs #89's checklist
  as a command. It resolves the model first: for HTTP kinds that's the
  endpoint's id plus whether `GET /models` serves it, and for acp it's the
  agent's own report. Then it makes one `completeReply` per `backend.Task`,
  each asking for a fixed token, and one real `repairPatch` (repair prompt
  plus sanitizer) on an unclosed `{% if %}`. Each row records latency,
  finish reason, answer/reasoning bytes, metered usage and shape
  (`exact` / `loose` / `wrong`). Exit 1 on any bad row. A sponsor kind
  without `MODEL_API_KEY`, or compat without a URL, fails before any call.
- **`acp.probe`** does a free handshake: `initialize` + `session/new`, no
  prompt, no tokens. It reads the agent's model and effort from
  `configOptions` (category `model` / `thought_level`), else
  `models.currentModelId`. `knap-mcp backends --probe` now covers acp, and
  every row's status comes from `backend.statusLine`.
- **`scripts/providers.sh`** has one case arm per profile, setting
  `backend`, `label` (provenance), `needs`, `cmds`, `expect` (a model glob)
  and the env. Private profiles go in `~/.config/knap/providers.sh`
  (`knap_profile_local` + `KNAP_PROFILES_LOCAL`) and are tried first.
- **`scripts/live.sh`** runs smoke first on every profile. If the resolved
  model doesn't match `expect`, or any smoke row fails, it stops that
  profile before the evals (`--force` overrides). It then runs:
  - repair: `eval/seeds.json`, plus `seeds.2nap.json` with `--full`
  - ratchet: `eval/ratchet.live.json`
  - voice: voice the sample data per tone on the live backend, render
    original and voiced, and require equal structure hashes

  Each profile writes `<out>/<profile>/{suite}.out|.err`,
  `provenance.json` (label, model, effort, git sha, engine pins, commands,
  exit codes, seconds) and `summary.txt`, then the runner prints a
  cross-profile table. A rerun replaces only the suites it runs, so
  `--suite repair --full` later adds the 2nap corpus without losing the
  ratchet and voice results. ratchet-eval exits 1 when a live model misses the
  mock-tuned bar. That is recorded, not counted as a harness failure.
- **Fix in `backend.zig`:** `acpReply` parsed ACP `usage` but never called
  `ctx.countUsage`, so acp token totals always read 0.
- The fake ACP agent gains `configOptions` on `session/new`, plus `echo` and
  `legacy` modes. The `fake` profile uses it.

## Findings from the first runs (2026-10-27)

1. **The opencode recipe on #90/#91/#92 never reached Muse.**
   `KNAP_ACP_AGENT='env OPENCODE_CONFIG_CONTENT={"model":"…"} opencode acp'`
   goes through knap-mcp's argv splitter, which groups on `"`. opencode
   therefore receives `{model:opencode/muse-spark-1.3}`, which is not JSON,
   and silently falls back to `opencode/flint-40b-free`. The model guard
   caught this on its first run. The profile now single-quotes the
   assignment. **Any number labeled "Muse Spark via ACP (opencode)" from
   that recipe is flint-40b-free.** None is committed under
   `eval/results/live/`. The 2026-10-26 smoke figures in the #90/#91
   comments are affected.
2. **The opencode account is out of funds.** With the right model selected,
   every opencode call fails with `Upstream request failed: Insufficient
   account funds`. The profiles are ready the moment it's topped up.
3. **Agent overhead is now measured.** With usage counted, devin turns
   carry about 13.5k prompt tokens (wonder) or 12.9k (swe-2) against a
   knap slice of about 75–420 B. That's the agent's own system prompt.
   ACP columns measure model plus agent, as the provenance labels say.
4. **The sponsor HTTP path works end to end against a stand-in server.**
   This used a local OpenAI-compatible stub (not committed),
   `KNAP_SPARK_URL=http://127.0.0.1:…` and a dummy `MODEL_API_KEY`.
   `live.sh spark` reported `served: yes` and smoke 6/6. `compat` did the
   same. When the real key lands, only the URL/model defaults are
   unconfirmed, and smoke's `served:` column checks them.
5. **Re-verified keyless 2026-10-27 (second run).** `make test`,
   `make eval` (mock, seeds + 2nap), `make ratchet-eval`,
   `make voice-eval` and `make demo` all green; `live.sh` re-ran
   devin-wonder, devin-swe-2 and devin-summarizer end to end. The
   `ollama` profile also ran against a local `qwen2.5(-coder):1.5b`:
   `served: yes`, correct model resolution, metered usage — the whole
   compat HTTP path works — but the repair-patch smoke row gets a wrong
   shape at 1.5B (12-token replies, no patch), so the fail-fast gate
   correctly stopped it before the evals. Use a bigger local model for
   real numbers.
6. **Two more coding-plan profiles wired: `gemini` and `codex`.** Both
   handshake, report their model and gate correctly. Both are currently
   blocked on the account, not the harness: gemini-cli's auth answers
   prompts with a suspended-project 403, and the codex-acp adapter
   (which needs `-c 'model="…"'` — its gpt-5.5 default isn't on ChatGPT
   accounts) gets `model_not_found` for every slug in
   `~/.codex/models_cache.json`. Once the user picks a model their plan
   accepts (or uses an API key), both are one `make live P=…` away.
7. **ACP prompt framing (`acpReply`) fixed `knap_voice` meta-refusals and
   agent tool use.** `acpReply` previously concatenated `system` and `user`
   with bare `\n\n`. Because `knap_voice`'s system prompt ends with
   `## Examples` (`Field: …\nRole: …\nInput: …\nOutput: …`), the user block
   blended into the examples and caused models (`nemotron-3.5-super`, etc.)
   to reply that no input was provided (rejecting 4 of 8 fields). Wrapping
   ACP prompts with a no-tools instruction and an explicit `\n\n## Request\n\n`
   boundary brought `droid-nemotron` to **8/8 rewritten, 0 rejected** across
   `mild`, `spicy`, and `feral`.
8. **Live-model `knap_ratchet` schema & slice fixes lifted `ratchet.live.json`
   from 3/9 to 9/9 in post-fix reruns.** The post-fix numbers were never
   committed — the in-tree `ratchet.out` artifacts are the pre-fix runs, so
   they are marked † in the results table below (#205). Live ACP runs
   exposed four issues in `src/ratchet.zig`:
   - `parseShape` left container types (`array<object>`, `object<string,string>`,
     `max_items`) in `slot.schema`, causing models to wrap single-step items
     in `[…]` or `{"key": "val"}` and fail `checkSchema`. `slot.schema` now
     emits the single-step item type (`object`, `string`, `array<string>`).
   - `run` unwraps 1-element arrays (`[item] -> item`) for `.strings`,
     `.objects`, and `.rows` slots before `checkSchema`.
   - `checkSchema` gained recursive `checkObject` validation so nested arrays
     of objects (e.g. `sources[+].quotes`) validate instead of failing with
     `quotes: expected a string`.
   - `buildSlice` raised the `HEADLINE` prose cap from 160 B to 400 B so
     `tldr` / `summary` fields in `.min.json` inputs (`213–309 B`) stay in
     `HEADLINE`.
   - `eval/ratchet.live.json` dropped the mock-only `"stop": "stalled"` on
     `apparatus-min` now that live models climb all 6 iterations (`+21.5` to
     `+25.2` gain).

## Results

Engines k4o `aeba163` / dogbed `d96b125`, density/2, knap-mcp `2292117`
plus this branch. Raw outputs and provenance are in
`knap-mcp/eval/results/live/<profile>/`.

| profile | model (agent-reported) | smoke | repair `seeds.json` | ratchet `ratchet.live.json` | voice (verdict) |
|---|---|---|---|---|---|
| droid-nemotron | `nemotron-3.5-super`, effort none | 6/6 ok, 1.7 s/call | 17/22 conv (77%) † | 8/9 ok † (`verdict-min` +38.6, `reading-note-min` +40.1, `release-notes-min` +28.9) | 3/3 layout-identical (`mild` 8/8, `spicy` 8/8, `feral` 8/8, **0 rejected**) |
| droid-glm | `glm-5.3-flash`, effort none | 6/6 ok, 5.8 s/call | 14/22 conv (64%) † | **9/9 ok** † (`verdict-min` +37.4, `reading-note-min` +26.7, `release-notes-min` +29.3) | 3/3 layout-identical (`mild` 8/8, `spicy` 8/8, `feral` 5/8) |
| droid-deepseek | `deepseek-v4.1-flash`, effort none | 6/6 ok, 2.3 s/call | 15/22 conv (68%) † | — | 3/3 layout-identical (`mild` 8/8, `spicy` 8/8, `feral` 4/8) |
| devin-nemotron | `nemotron-3-ultra-high` | 6/6 ok, 1.5 s/call | — | 8/9 ok † (`verdict-min` +37.0, `reading-note-min` +45.3, `apparatus-min` +25.2) | 3/3 layout-identical (`mild` 5/8, `spicy` 6/8, `feral` 6/8) |
| devin-wonder | `muse-wonder-1-0-high`, effort low | 6/6 ok, 2.5 s/call | 22/22 conv, 1.05 iters, 11/22 exact (2nd run; first runs 1.09/1.05 iters, 8/22, 10/22 exact); 2nap 167/167, see I2.md | 3/9 ok (pre-fix), **inert 0** | 2/2 layout-identical (feral: 1 of 8 rejected) |
| devin-swe-2 | `swe-2-high`, effort medium | 6/6 ok, 2.2 s/call | 22/22 conv, 1.09 iters, 9/22 exact | 3/9 ok, **inert 0** (committed, pre-fix); post-fix rerun reported **9/9 ok** † (`reading-note-min` +52.0 ceiling, `release-notes-min` +29.4, `verdict-min` +22.7, `apparatus-min` +21.5) | 2/2 layout-identical, `mild` 7/8 + `feral` 6/8 (committed); a 3-tone rerun † reported `mild` 8/8, `spicy` 7/8, `feral` 4/8 |
| devin-summarizer | unreported | 6/6 ok | (I2/I3 columns) | | |
| ollama (qwen2.5-coder:1.5b, local) | `qwen2.5-coder:1.5b` | 5/6 ok, repair-patch wrong shape | gated off | | |
| gemini (gemini-cli `--acp`) | `gemini-1.5-flash` | 0/6: 403 "Consumer 'projects/undefined' has been suspended" — account-side auth | | | |
| codex (`@zed-industries/codex-acp`) | `gpt-6-luna` | 0/6: "model is not supported when using Codex with a ChatGPT account" for every cached slug | | | |
| opencode-spark-1.3 / -1.2 / wonder-1.0 | correct model | 0/6: insufficient account funds | | | |
| spark / wonder / baseten | | skipped: needs `MODEL_API_KEY` | | | |

† uncommitted rerun; raw outputs not in tree (#205). Only smoke and voice
artifacts are committed for the droid-* / devin-nemotron profiles, and the
in-tree `devin-swe-2/ratchet.out` predates the #195 ratchet schema fixes.

Labels: `Muse Wonder 1.0 via ACP (devin, low thinking)` and `SWE-2 via ACP
(devin, free tier)`. These are not direct-API numbers.

## Adding a provider

- **Any OpenAI-compatible endpoint** (OpenRouter, CLIProxyAPI, vLLM): set
  `KNAP_COMPAT_URL`, `KNAP_COMPAT_MODEL`, optional `KNAP_COMPAT_KEY` and
  `KNAP_COMPAT_LABEL`, then run `make live P=compat`.
- **Local ollama:** `ollama serve`, `ollama pull <m>`, then
  `OLLAMA_MODEL=<m> make live P=ollama`.
- **Any ACP agent:** add a case arm with `backend=acp`, `expect=<glob>` and
  `export KNAP_ACP_AGENT='…'`. Run `knap-mcp backends --probe` once to see
  what model id the agent reports.
- Keys only ever come from the environment. Never put them in a profile:
  `KNAP_ACP_AGENT` shows in `ps`.

## Gate

```sh
make test
KNAP_MCP_HOME=$(mktemp -d) make eval    # byte-identical to main, report: lines aside
make live P=fake
```
