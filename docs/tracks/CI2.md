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

## For other lanes

- `scripts/install-boris.sh` is generic (tag/zig-version/dest args) — any
  lane that needs a pinned boris on a fresh machine can reuse it.
- If a lane changes what `make demo` needs (new tool on PATH), update this
  job or the beat will silently skip.
