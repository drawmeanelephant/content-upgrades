# BE: env-handling hardening for live backends (issue #209)

Lane BE. Owner files: `src/backend.zig`, `src/ctx.zig`, this note. Issue
#209 — three operator-env-controlled holes around the curl live path.

## What landed

### #209.1 — URL scheme validation + `--` in curl argv

- `endpoint()` now validates the resolved URL: anything not starting
  `http://` or `https://` is a `ToolFailed` naming the env var
  (`KNAP_SPARK_URL must start with http:// or https://`). Applies to
  `KNAP_<KIND>_URL` and `KNAP_<KIND>_MODELS_URL` for SPARK, WONDER,
  BASETEN and COMPAT — a derived models URL keeps its parent's scheme,
  an env-set one goes through the same gate.
- `curl()` builds argv with the URL moved to the end behind `--`
  (curl's end-of-options marker), so a value that survives validation
  can still never parse as a curl option. Every option now precedes it:
  `-sS --fail-with-body -X <m> -m <s> --connect-timeout <s> -K - -w …`
  then the payload's `-H`/`--data-binary`, then `-- <url>` last.
- New helpers: `envVarName(kind, suffix)` (runtime spelling of the
  `envName` comptime names, so errors can name the env var — also
  adopted in `listModels`) and `isHttpUrl`.

### #209.2 — API key vetted before the `-K` config stream

- `apiKey` runs every key through `checkKey`, which rejects `"`, `\`
  and ASCII control bytes (≤0x1F, 0x7F) — the bytes that would break
  out of `header = "Authorization: Bearer {s}"` in the stdin curl
  config and inject directives. Rejects rather than escapes: none of
  those bytes is valid in a bearer token anyway.
- The error names the env var (`MODEL_API_KEY` / `KNAP_COMPAT_KEY`),
  never the key — the no-key-material-in-argv/logs/errors guarantee
  is kept and asserted by the new test. `authConfig`'s doc comment
  records that its input must come from `apiKey`.

### #209.3 — bogus KNAP_BACKEND fails init

- `ctx.zig`: `backendKind(env)` replaces the silent
  `parseKind(...) orelse .mock`. Unset or blank-after-trim → mock as
  before; a set-but-unknown value prints
  `KNAP_BACKEND '<v>' is not a backend kind (mock|spark|wonder|baseten|acp|compat)`
  to stderr and returns `error.InvalidKNAP_BACKEND`, which `main`
  reports as `init failed: InvalidKNAP_BACKEND` and exits 1. Every CLI
  `--backend` flag already failed loudly; the env var now matches.

## Interface notes for other lanes

- `Ctx.init` can now fail with `error.InvalidKNAP_BACKEND`; `main`'s
  generic `init failed: <name>` print covers it — no main.zig change
  needed (ctx.zig was already in the test-import block).
- `main.zig` usage text (merge captain's shared file) may want
  `http:// or https://` noted on the `KNAP_<KIND>_URL` rows.
- Behavior for valid env is unchanged: mock eval never touches
  `endpoint`/`curl`/`apiKey`; `KNAP_BACKEND` unset → mock as before.

## Gates

- `make test` — includes new tests: non-http(s) URL rejection (file://,
  dict://, gopher://, ftp://, leading-dash, schemeless) for `URL` and
  `MODELS_URL`, key rejection (`"`, `\`, newline, tab, DEL) for
  `MODEL_API_KEY` and `KNAP_COMPAT_KEY`, and `backendKind` accept/fail.
- `KNAP_MCP_HOME=$(mktemp -d) make eval` — mock path untouched.
- Gate output could not be run from this lane's environment (no
  exec permission for zig/make/git in background); the diff was
  reviewed in full and `std.ascii.isControl` verified against the
  installed stdlib. Merge captain should run `make test` +
  `make eval` before merge.
