# ENGINES: scripts/engines.sh + engine pins

Issue #280: `make engines` failed on a fresh machine because the script
required the k4o/dogbed sources pre-cloned under `~/dev` (or
`$KNAP_ENGINES_SRC`), while the README never mentions such a checkout.

## What changed

- `build()` still prefers `$KNAP_ENGINES_SRC/<name>` (default `~/dev`)
  when that checkout already contains the pinned commit — no network.
- Otherwise `fetch_repo()` reproduces CI's old recipe in a scratch repo:
  `git init`, `remote add origin https://github.com/drawmeanelephant/<name>`,
  `fetch --depth 1 origin <sha>` (GitHub serves reachable SHAs), then
  `git archive` as before. The scratch repo lands in `$TMPDIR` and is
  removed by an EXIT trap; `$KNAP_ENGINES_SRC` is never written to.
- `KNAP_ENGINES_OFFLINE=1` opts out of the fetch and keeps the old
  "commit … not found in …; fetch it there first" error (exit 1).
- The build log line now names the source: `building <name> at <sha> from
  <repo>`; the fetch prints one line naming the URL.
- CI: both "Build pinned engines" steps collapsed to `make engines`
  (engines.sh now fetches itself), and the demo step's stale
  `KNAP_ENGINES_SRC=$RUNNER_TEMP/src` pointer was dropped — the demo job
  no longer populates that dir. The "Read engine pins" steps stay; the
  cache key still hashes the two pin lines.

## Verified

- `KNAP_ENGINES_SRC=$(mktemp -d) KNAP_ENGINES_DIR=$(mktemp -d) make engines`
  fetches + builds both pins; source dir left empty; no scratch repos
  remain under `$TMPDIR`.
- `KNAP_ENGINES_OFFLINE=1 KNAP_ENGINES_DIR=$(mktemp -d) scripts/engines.sh`
  with `~/dev` checkouts present builds both pins with zero network —
  existing-checkout path is unchanged.
- `KNAP_ENGINES_OFFLINE=1` + empty `KNAP_ENGINES_SRC` prints the old error
  and exits non-zero.
- `make test` (261/261), `KNAP_MCP_HOME=$(mktemp -d) make eval` green.

## Notes for other lanes

- Nothing under `~/.cache/knap-engines` is ever overwritten — unchanged.
- A pin bump is still a one-line `*_SHA=` change in its own PR.
