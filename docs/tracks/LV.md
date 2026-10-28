# LV: live-provider harness hygiene (issues #204, #205)

Lane LV. Owner files: `scripts/live.sh`, `scripts/providers.sh`,
`knap-mcp/eval/results/live/**`, `docs/tracks/LIVE.md`, this note.

## What landed

### #204 — harness hygiene

- **Provenance `command` bug.** `suite()` built the recorded command as
  `knap-mcp${cmdline#"$bin"}`; for the voice suite `$1` is the shell
  function `voice_suite`, so six committed `provenance.json` files said
  `"command": "knap-mcpvoice_suite"`. `suite()` now records
  `<fn> (shell function in scripts/live.sh)` for non-`$bin` commands, and
  the six files (devin-wonder, devin-swe-2, devin-nemotron, droid-glm,
  droid-deepseek, droid-nemotron) were corrected to match.
- **Temp litter.** The per-profile subshell leaked both
  `KNAP_MCP_HOME=$(mktemp -d)` and, for `scratch` profiles, the results
  dir `$(mktemp -d)/$p`. An `EXIT` trap now removes both. Scratch results
  still print in the summary table; the run reports where they went and
  that `--out` keeps them.
- **Predictable /tmp cfg.** `knap_droid` wrote
  `${TMPDIR:-/tmp}/knap-droid-$1.json` — a fixed, world-readable path
  (symlink-clobber risk) that was never removed. It now uses `mktemp`,
  appends the path to `KNAP_TMP_FILES`, and installs an `EXIT` trap.
  `resolve()` only ever runs inside `live.sh` subshells, so the file
  dies with the readiness probe or the profile run; `live.sh`'s own
  cleanup trap also removes `$KNAP_TMP_FILES`, which is the registration
  point for any future per-profile scratch files.
- **Committed agent stderr.** `eval/results/live/codex/smoke.err` held
  ~1.2 MB of `codex-acp` stderr from a `KNAP_DEBUG=1` run (`acp.zig`
  inherits agent stderr under KNAP_DEBUG, and it may carry account
  details). Replaced with a stub pointing at `provenance.json` /
  `summary.txt` — the `note:` fields there are parsed from `smoke.out`,
  not `smoke.err`, so nothing referenced the scrubbed content. `live.sh`
  now `unset KNAP_DEBUG`s so a debug env can never land agent logs in
  committed `.err` files again.
- **"Stray" top-level artifacts — kept.** `acp-seeds.{out,err}`,
  `acp-seeds.2nap.{out,err}`, `acp.ratchet.json`, `acp.txt`,
  `acp.stderr.txt`, `mock.txt` are not produced by the current
  per-profile layout, but they are the I2/I3 lanes' raw outputs and are
  still consumed: `demo/card/build.sh` parses them into
  `demo/card/numbers.json`, `demo/run.sh` greps them,
  `demo/tapes/08-numbers.tape` + `demo/storyboard.md` reference them, and
  `docs/tracks/I2.md`/`I3.md`/`I4.md` document them. Deleting them would
  break the demo card build, which belongs to another lane. Left in
  place; noted on #204.

### #205 — LIVE.md numbers not reproducible

No rerun was possible in this session (no `devin`/`droid` CLIs invoked
from this lane; nothing was faked). Every table number now either traces
to a committed artifact or carries the † mark ("uncommitted rerun; raw
outputs not in tree"):

- `devin-swe-2` ratchet: committed `ratchet.out` is the pre-fix 3/9 run;
  the 9/9 claim and its per-case gains are marked †, and finding #8's
  "3/9 to 9/9" now says the post-fix numbers were never committed.
- `devin-swe-2` voice: committed is 2/2 (`mild` 7/8, `feral` 6/8); the
  previous 3-tone claim (`mild` 8/8, `spicy` 7/8, `feral` 4/8) is marked †.
- `droid-glm` repair 14/22 + ratchet 9/9, `droid-deepseek` repair 15/22,
  `droid-nemotron` repair 17/22 + ratchet 8/9, `devin-nemotron` ratchet
  8/9 — all marked †; only smoke+voice artifacts are in tree for those
  profiles.
- Verified consistent with committed artifacts: `devin-wonder` (repair
  22/22 1.05 iters 11/22, 2nap 167/167, ratchet 3/9 pre-fix, voice 2/2),
  `devin-swe-2` repair 22/22 1.09 iters 9/22, and all committed voice
  cells (`droid-nemotron` 8/8+8/8+8/8, `droid-glm` 8/8+8/8+5/8,
  `droid-deepseek` 8/8+8/8+4/8, `devin-nemotron` 5/8+6/8+6/8).

## Interface notes for other lanes

- `KNAP_TMP_FILES` is a space-separated accumulator a profile can append
  scratch files to; `live.sh`'s per-profile `EXIT` trap removes it.
- `live.sh` unsets `KNAP_DEBUG`. To debug an ACP agent's stderr, invoke
  `knap-mcp` directly with `KNAP_DEBUG=1`, not through `live.sh`.
- The voice suite's provenance `command` is now a descriptive string
  (`voice_suite (shell function in scripts/live.sh)`), not a fake
  `knap-mcp` argv — anything scraping that field should not assume it
  starts with `knap-mcp `.

## Gates

- `make test` — run by the merge lane (shell-only changes; nothing in
  `src/**` touched).
- `make live P=fake` — green; provenance `command` reads
  `knap-mcp smoke --backend acp`; with `SUITE=all` the voice run records
  `voice_suite (shell function in scripts/live.sh)`. No `mktemp` dirs or
  `/tmp/knap-droid-*` files remain after a run (scratch results are
  removed unless `--out` is given).
