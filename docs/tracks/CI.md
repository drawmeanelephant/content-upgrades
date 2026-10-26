# CI: GitHub Actions

Status: `.github/workflows/ci.yml` is the repo's first CI. One job on
`ubuntu-latest`, triggered on `pull_request` and pushes to `main`, with
`concurrency` cancelling superseded runs per ref and
`permissions: contents: read`.

## What the job does

1. **Zig 0.17.0** via `drawmeanelephant/zig-zouave` pinned by commit SHA —
   the same action and pin comment k4o's CI uses.
2. **Engine pins.** The `K4O_SHA=` / `DOGBED_SHA=` lines are grepped out of
   `scripts/engines.sh`; their sha256 is the `actions/cache` key for
   `~/.cache/knap-engines`, so a pin bump rebuilds the engines and nothing
   else invalidates the cache.
3. **Engine sources.** Each pinned SHA is fetched into
   `$RUNNER_TEMP/src/<name>` with `git init` + `git fetch --depth 1 origin
   <sha>` (GitHub serves reachable SHAs, so no full clone is needed).
   `make engines` then runs with `KNAP_ENGINES_SRC=$RUNNER_TEMP/src` and
   `KNAP_ENGINES_DIR=$HOME/.cache/knap-engines`; `engines.sh` builds from a
   `git archive` of the pinned commit and installs
   `<name>-<sha7>/<name>` under the cached dir.
4. **Gates:** `make test`, `KNAP_MCP_HOME=$(mktemp -d) make eval`, and
   `sh knap-mcp/prompts/voice/check.sh` — the same sequence AGENTS.md
   requires before a PR.

## Design notes

- `KNAP_ENGINES_DIR` is passed inline (`$HOME` expands in the run shell;
  the `env:` context can't reference it). The value matches engines.sh's
  own default; it is set explicitly so the cache path and the build path
  can't drift.
- No `restore-keys` on the engine cache: a stale pin dir is dead weight,
  and engines.sh never overwrites an existing `<name>-<sha7>/` dir, so
  partial restores are safe either way — exact-key-only keeps the cache
  from growing.
- `make eval` exits 0 with unconverged mock seeds (it reports a table, it
  does not gate on the convergence rate), so the eval step asserts that
  the pipeline runs end-to-end on the pinned engines, not a quality bar.

## Not covered: boris

The `boris-site/` scripts (`selftest.sh`, `stage-check.sh`, `build.sh
--check`, `bench.sh`) need the `boris` binary (`BORIS=` env or on PATH;
B1 measured against `boris/0.8.2`, `ask.sh` also needs `jq`). boris is an
external tool, not built from this repo, so a CI step would need a pinned
boris release artifact or a source build installed first. Left out until
there is a pinned, fetchable boris distribution.

## Also not done here

- Branch protection / required checks — a repo-settings decision for the
  owner.
- Changes to `scripts/engines.sh` or the Makefile — none were needed;
  the workflow drives both through the env vars they already honor.
