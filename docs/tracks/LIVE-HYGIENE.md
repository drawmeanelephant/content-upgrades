# LIVE-HYGIENE: what live-eval output stays committed (issue #277)

Lane LIVE-HYGIENE. Owner files: `scripts/live.sh`,
`knap-mcp/eval/results/live/**` (untracking only),
`knap-mcp/eval/results/live/.gitignore`, this note.

## The problem

`scripts/live.sh` wrote into `knap-mcp/eval/results/live/` by default, so
every live run landed raw, host-specific output in a tracked path. That is
how a `KNAP_DEBUG=1` run committed ~1.2 MB of codex-acp stderr with an
account/model payload (#204; the history copy is #281). #204 fixed the
harness, not the practice.

Live runs need accounts, so CI cannot regenerate any of this. "Publish as
CI artifacts" is not an option for live output: whatever the demo, the
card and the track notes cite has to stay in the tree.

## Policy

A file under `eval/results/live/` stays tracked when it is evidence: the
demo, the card or a track note reads or cites it. Raw stderr and
re-derivable per-run payloads are not evidence.

**Tracked** (56 files):

| class | why |
|---|---|
| `*.out` | the result tables. `demo/run.sh` beat 8 greps `acp-seeds.2nap.out`, `devin-wonder/{repair-seeds.2nap,ratchet}.out`; `demo/card/build.sh` parses `acp-seeds{,.2nap}.out` and `devin-wonder/repair-seeds{,.2nap}.out`; LIVE.md's table cites every profile's `smoke`/`repair-seeds`/`ratchet`/`voice` `.out` |
| `<profile>/summary.txt`, `<profile>/provenance.json` | model, effort, git sha, engine pins, commands, exit codes and seconds per run; the "measured-only" provenance behind LIVE.md |
| `acp.txt`, `mock.txt` | I3 ratchet tables; the demo and the card read both |
| `acp.ratchet.json` | I3's stored `knap://docs/…` report with per-step detail, cited in I3.md |
| `acp.stderr.txt` | the one stderr file kept: it holds `time` output (`real 1m16.710s`), the source of I3.md's "76.7 s wall". It is not agent stderr. |

**Untracked** (42 files, `git rm --cached`, still on disk in existing
checkouts):

| class | count | why |
|---|--:|---|
| `*.err` | 26 | raw stderr. 19 are empty. 6 `voice.err` hold only `calls:` counter lines, which are prompt-size constants (the same for every model; the mock values are in EVAL.md). `codex/smoke.err` is the #204 scrub stub. Nothing reads or cites any of them. |
| `<profile>/voice-verdict-*.json` | 16 | per-run voice payloads. The current `live.sh` no longer writes them (it deletes `voice-*.json` before each voice run), so they were orphaned and a voice rerun would have deleted tracked files. Every number LIVE.md cites from them (changed / rejected per tone) is in the same profile's `voice.out` table. |

`provenance.json` still names each run's `err` file. That records what the
run wrote; the file just isn't committed. Recorded numbers are unchanged.

## Default is safe

- `live.sh` defaults `--out` to `${XDG_CACHE_HOME:-~/.cache}/knap-live`,
  outside the repo and user-private (a fixed `/tmp` path was the #204
  symlink-clobber pattern). It is a stable dir, so a later
  `--suite repair --full` still merges into an earlier run's provenance.
  `make live P=...` passes no `--out` and inherits this.
- `scratch` profiles (`fake`) keep their behavior: a temp dir removed on
  exit unless `--out` is given.
- To update the record, opt in explicitly:

  ```sh
  scripts/live.sh --out knap-mcp/eval/results/live --suite all devin-wonder
  ```

  Then commit only the tracked classes. `eval/results/live/.gitignore`
  ignores `*.err`, `*.stderr.txt` and `voice-*.json`, so `git add` of the
  profile dir picks up `.out`, `summary.txt` and `provenance.json` only.

Issue step 4 (refuse `*.err` in a tracked path under `KNAP_DEBUG`) is not
needed: `live.sh` already `unset`s `KNAP_DEBUG` (#204), and `.err` is now
ignored in the record dir, so a debug run cannot be committed by a plain
`git add`.

## Verification

- A default `scripts/live.sh <profile>` run with a non-scratch profile
  (a local profile pointing at the fake ACP agent, via
  `KNAP_PROVIDERS_LOCAL`) writes to `~/.cache/knap-live/<profile>/` and
  leaves `git status` clean. With `--out knap-mcp/eval/results/live`,
  `git status` shows only a new `.out`/`summary.txt`/`provenance.json`;
  the `.err` files are ignored.
- `git ls-files knap-mcp/eval/results/live | rg '\.err$'` is empty.
- `make demo` transcript and artifacts and `demo/card/build.sh --json`
  output are byte-identical to `main`, run from a clean export of the
  branch (no untracked `.err`/voice JSON on disk).

## For other lanes

- `docs/tracks/I2.md` says "Raw: … (+ `.err`)" for the four repair runs
  and I3.md mentions `ratchet.err`. Those files were empty and are no
  longer tracked; the citations are stale but cite no numbers.
- LIVE.md's quick-start (`make live P=...`) now writes out of tree. A line
  there pointing at `--out knap-mcp/eval/results/live` for recording runs
  would help; LIVE.md is not this lane's file.
