# COMPAT: generic OpenAI-compatible backend

Issue #147. `compat` is the same curl `chatCompletion` path the sponsor
kinds use, with no built-ins: `KNAP_COMPAT_URL` and `KNAP_COMPAT_MODEL`
are required (each missing var fails with its own message), and
`KNAP_COMPAT_KEY` is an optional bearer — unset sends **no**
`Authorization` header at all (`authConfig` returns ""), never an empty
`Bearer`. `MODEL_API_KEY` is never consulted for `compat`, so a proxied
column can run side by side with the sponsor columns once #85 lands.

`KNAP_COMPAT_MODELS_URL` / `_TEMPERATURE` work as for other kinds
(`…/chat/completions` → `…/models` derivation included). `needsKey` is
false, so voice / ratchet / verifier-decision all accept it.
`knap-mcp backends` shows a `compat` row (resolved model + key state, key
never printed); `--probe` runs its model list too. Drive-by fix:
`knap_verify_citation`'s schema enum was missing `"acp"`; it now lists
all six kinds like the other tools.

## Env recap

```
KNAP_COMPAT_URL         required, e.g. http://127.0.0.1:8317/v1/chat/completions
KNAP_COMPAT_MODEL       required, e.g. muse-spark-1.3
KNAP_COMPAT_KEY         optional bearer (proxy api-keys entry, if you set one)
KNAP_COMPAT_MODELS_URL  optional (default: URL-derived)
KNAP_COMPAT_TEMPERATURE optional (0..2 or omit)
```

## CLIProxyAPI recipe (internal shakedown)

CLIProxyAPI (MIT) fronts subscription logins with a local
OpenAI-compatible endpoint and has a native Meta (Muse Code) provider:

1. Install a release at least 7 days old — they ship almost daily; a
   pinned binary release (e.g. v8.0.32, 2026-10-16, already has the Meta
   provider) beats the rolling Homebrew bottle. No Docker.
2. Bind `127.0.0.1` only, set a client key under `api-keys`, do the Meta
   device-flow login, keep its config/tokens out of the repo.
3. Then:

   ```sh
   export KNAP_COMPAT_URL=http://127.0.0.1:8317/v1/chat/completions
   export KNAP_COMPAT_MODEL=<model id the proxy lists>
   export KNAP_COMPAT_KEY=<the api-keys entry>
   knap-mcp backends --probe
   ```

Any other OpenAI-compatible endpoint works identically — OpenRouter, a
local ollama (`http://127.0.0.1:11434/v1/chat/completions`), llama.cpp,
vLLM. With no key needed, leave `KNAP_COMPAT_KEY` unset.

## Provenance rule

Results produced through a proxy are labeled by what they are — e.g.
`Muse Spark 1.3 via CLIProxyAPI (Muse Code account)` — kept in their own
files under `knap-mcp/eval/results/live/compat-<model>.*`, and never
presented as direct Meta API numbers. Whether a subscription-backed proxy
is acceptable under Meta's terms is unresolved, so proxied numbers are
internal only: they don't appear in the demo video or the README.

## Gate

```sh
make test                        # compat unit tests in backend.zig
KNAP_MCP_HOME=$(mktemp -d) make eval   # byte-identical: no behavior change for existing kinds
```
