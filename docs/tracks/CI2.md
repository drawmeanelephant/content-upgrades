# Track CI2: `make demo` in CI

Adds a `demo` job to `.github/workflows/ci.yml` that runs the full scripted
demo (`make demo`, all 9 storyboard beats on the mock backend) on
`ubuntu-latest`, including beat 5 (`publish_check`) against a real boris
binary.

## Findings

- `demo/run.sh` is already CI-shaped: no tty, no network, no vhs/ffmpeg —
  those are `demo/build.sh` (video pipeline) deps, not the demo's. Runner
  needs only `jq` (preinstalled), the pinned engines, and a `zig build` of
  knap-mcp.
- Beat 5 is the only gap: it needs `KNAP_BORIS_PATH` (demo/run.sh:36 skips
  cleanly if unset — so the job is green either way, but we want the beat
  exercised).
- boris ships **no prebuilt binaries**. `drawmeanelephant/boris` tags are
  source releases; the field-guide repo also builds the pinned release from
  source on the runner. Acquisition method: clone tag `v0.8.2`, `zig build`.
- Toolchain subtlety: v0.8.2 predates boris's Zig 0.17 migration, so it is
  built with **Zig 0.16.0**, fetched sha256-verified from ziglang.org's
  index.json by `scripts/install-boris.sh`. knap-mcp still builds on the
  repo's pinned 0.17.0 — only the boris build uses 0.16.0.
- `src/boris.zig`, B1, B2 were all measured against boris 0.8.2 (B1's
  binary reported vcsRevision `897611b7`).

## What the job does

1. Same zig-zouave + engine-pin cache as `build-test-eval` (identical cache
   key — both jobs share `~/.cache/knap-engines`).
2. `scripts/install-boris.sh` → `~/.cache/knap-boris/v0.8.2/boris`, cached
   under `knap-boris-<os>-v0.8.2-zig0.16.0`. Idempotent; cache hit skips the
   whole build.
3. `KNAP_BORIS_PATH=… make demo` — all beats, beat 5 runs for real.
4. `boris-site/selftest.sh` with the same binary — a much heavier exercise
   of boris (check/validate/artifact regen) that catches a subtly wrong
   build.
5. `actions/upload-artifact` of `demo/out/demo/` (transcript + artifacts)
   on success or failure.

`needs:` deliberately omitted — the job runs in parallel with
`build-test-eval` and shares the engine cache by key.

## What is skipped (and why)

- `demo/build.sh` video pipeline (vhs → ffmpeg → mp4): needs
  vhs/headless-Chrome/ttyd — out of scope; beats are exercised as scripted
  commands, not recorded.
- Live backends: `make demo` is mock-only by design.

## Fallback

If the boris build ever breaks on the runner, dropping the two boris steps
still leaves a useful job: `make demo` passes with beat 5 printed as
SKIPPED (demo/run.sh exits 0).

## Root cause: "engine terminated abnormally" (#74)

`make demo` beat 2 (and, intermittently, `make eval`) died with
`knap-mcp: engine terminated abnormally` on ubuntu-latest while passing on
macOS. It was a **SIGILL from AVX-512 instructions in a cached engine
build**. It was not a timeout, an env difference or a crash on the input.

- Before #73, `scripts/engines.sh` built pins with `zig build
  -Doptimize=ReleaseSafe`, which targets the *build machine's* CPU. The
  result was saved under one `actions/cache` key (`knap-engines-Linux-<pin
  hash>`) and restored by every later job, on whatever hardware it got.
- GitHub's ubuntu-latest pool mixes CPUs. A pin built on an AVX-512 host
  (Intel Xeon 8370C, AMD EPYC 9V45) SIGILLs on exec on an AMD EPYC 7763
  (Zen 3, no AVX-512). Whether a job failed depended on which CPU built
  the cache and which CPU restored it, so it looked like a coin-flip flake.
  It also explains why `build + test + eval` could pass while `demo` failed
  in the same run: they ran on different machines.
- Evidence (PR #109, run 40436053673): a temporary matrix job (6 runners)
  restored the old v1 cache and the current v2 cache side by side.
  - v1 `k4o`/`dogbed`: 2338/2807 `zmm` instructions. On all 3 EPYC 7763
    runners, `--help` exited 132 (128+SIGILL) and `knap-mcp validate` printed
    `engine 'k4o' killed by signal 4 (SIGILL)`. They passed on the 3 AVX-512
    runners.
  - v2 (`-Dcpu=baseline`): 0 `zmm`/`ymm` instructions, passed on all 6.
- A retry cannot fix this, because the same machine SIGILLs again. Run
  40433036659 failed even with #73's retry in place.

Fix: #73 already landed `-Dcpu=baseline` plus the `knap-engines-v2-` cache
key. Both jobs have been green since. #74 adds the following:

- `engine.zig` now names the termination:
  - `engine 'k4o' killed by signal 4 (SIGILL): <stderr head>`;
  - `stopped by signal N`, or `terminated abnormally (wait status N)`;
  - timeouts stay `timed out after Ns`.
  `knap_lint` fails the same way instead of returning empty diags.
- It removes #73's retry-on-signal. Its premise ("runners reap children
  spuriously") was wrong, and retrying a real crash only hides it and
  doubles its cost.

Rule for any future cached native build (engines, boris, anything shared
between runners or machines): build with `-Dcpu=baseline` and bump the
cache key when the build flags change.

## For other lanes

- `scripts/install-boris.sh` is generic (tag/zig-version/dest args) — any
  lane that needs a pinned boris on a fresh machine can reuse it.
- If a lane changes what `make demo` needs (new tool on PATH), update this
  job or the beat will silently skip.
- Env seam gotcha (cost one CI round): `stage-check.sh` reads `BORIS`,
  `demo/run.sh` and knap-mcp read `KNAP_BORIS_PATH`, and `selftest.sh`
  maps either onto the other. On a runner without a PATH boris, export
  **both** or the stage-check half of selftest fails `boris: not found`.
