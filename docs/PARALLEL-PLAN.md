# Parallel plan — many agents, normal pace

Snapshot: Oct 26 (kickoff day). Freeze Oct 30 EOD. Filter cut-line Oct 29 EOD.

## Where we are

Landed on `main` (PRs #1–#4):
- `knap-mcp`: MCP stdio server + dual-mode CLI, 6 tools (`templates`, `validate`,
  `render`, `repair`, `lint`, `format_check`), doc/template resources, artifact store.
- Backends: `mock` works; `spark`/`wonder`/`baseten` are wired over curl but never
  exercised (no `MODEL_API_KEY` in this environment).
- Repair loop (max 4) + seeded eval: mock converges 7/10, mean 0.80 iters.
- Templates: `verdict`, `apparatus`. `format_check`: 8 advisory rules.
- `zig build` and `zig build test` pass on Zig 0.17.0.

In flight elsewhere:
- k4o PR #70 (9 referential filters) is open, not merged.
- k4o parser tranche (`{% set %}`, `??`, `callout` tuples) is written but only
  staged in `../k4o-stage/` (untracked in the main checkout). Never applied,
  built, or tested: the Devin child's sandbox blocked zig/git/gh in `~/dev/k4o`.
  The "Configure GitHub PR and Branch Protection" thread said it would ship it.
- dogbed bundles an older k4o, so `render apparatus --target html` fails with
  `no filter named "wikilink"`.

Known defects found while surveying:
- Seed `wikilink-bad-arg` converges in 0 iterations: the mutation does not break
  the template, so the real score is 6/9 breaks, not 7/10.
- Main checkout is still on the merged `feat/apparatus-templates` branch.

Not started (SPEC/GAMEPLAN/README):
- **Density scorer + ratchet loop**. This is the README pitch and has no code yet.
- `knap_voice` + voice eval (structure-hash equality across tones).
- Frozen boris artifact, `knap_publish_check`, `boris_ask`, `boris_check`.
- Verifier slot (`decision-model | heuristic | none`).
- Real-model eval runs, larger seeded corpus (2nap triples + error cases).
- k4o conformance numbers (X/188 → Y/188), 3 more templates.
- Video pipeline smoke test, storyboard, vhs tapes (GAMEPLAN D3 is unchecked).

## Ground rules for tandem agents

1. **Own worktree, full exec.** Every child gets an isolated worktree and can
   run `zig`, `git`, `gh`. Both earlier Devin children lost a round-trip
   because their sandbox blocked builds. Use Opus 5.5 (normal speed) children
   via Factory Droid with worktree isolation. Add `~/dev/k4o` and
   `~/dev/dogbed` as T3 projects so engine children get worktrees too.
2. **Pinned engines.** Nobody points at `~/dev/k4o/zig-out` (a k4o agent's
   rebuild would change it under everyone). Track S0 adds
   `scripts/engines.sh`: builds pinned k4o/dogbed SHAs into
   `~/.cache/knap-engines/<sha>/` and the Makefile exports
   `KNAP_K4O_PATH`/`KNAP_DOGBED_PATH`. Pin bumps are their own PRs.
3. **One owner per file per wave** (table below). The only shared edits are
   one-line registry entries (tool registry, CLI table, test imports). The
   merge captain resolves those.
4. **No shared-doc edits.** Agents do not touch README/SPEC/GAMEPLAN. Each
   writes `docs/tracks/<id>.md`; the captain folds notes in at wave end.
5. **Gate per PR:** `make test` + `make eval` with pinned engines, plus the
   track's own gate. Branch `feat/<id>-<slug>`, small PR, per CONTRIBUTING.
6. **Merge captain** = the parent Opus thread. It merges in dependency order,
   rebases (linear history is enforced), reruns `make test` after each merge,
   and launches the next wave.
7. **Handback line:** PR URL, head SHA, gate output, one-paragraph handoff.

## Wave 0 — start now (8 lanes + 1 optional)

Nothing here waits on anything else. Only S0 touches the shared knap-mcp core.

| ID | Track | Owns | Gate / output |
|---|---|---|---|
| S0 | **Seams refactor.** Split `tools.zig` into `src/tools/<name>.zig` + a one-line-per-tool registry; table-driven CLI in `main.zig`; `backend.complete(ctx, kind, task, system, user)` with a `Task` enum (`repair`, `voice`, `verify`, `judge`); `scripts/engines.sh` + Makefile pinning; repo `AGENTS.md` with these rules. No behavior change. | `src/tools*.zig`, `src/main.zig`, `src/backend.zig`, `src/ctx.zig`, `build.zig`, `Makefile`, `AGENTS.md` | Eval table byte-identical to today; tests green. **Critical path; merge first.** |
| K1 | **Apply k4o parser tranche** from `k4o-stage/` on `feat/parser-blocks` stacked on #70; build, `verify.sh --update-readme`, PR. Confirm with the other thread first so it is not done twice. | `~/dev/k4o` | k4o PR, tests + verify green |
| K3 | **Conformance baseline.** Run the 188-case corpus through k4o at `main`, #70, and parser-blocks. Read-only on k4o. | `knap-mcp/eval/conformance/` | `X/188 → Y/188` table for the numbers card |
| B1 | **Freeze boris artifact.** Build a small real site (`boris init` + content) with search-index/RAG pack; measure `boris check` command shape and latency (incl. unlinked-reference detection). | `boris-site/`, `docs/tracks/B1.md` | Checked-in artifact + measured latency |
| D1 | **Density scorer core.** Pure `score(markdown) -> {total, signals}`: callouts, footnotes, tables, styled runs, heading/word ratio, lists, wikilinks/embeds, links vs raw URLs, frontmatter; `format_check` rules fold in as negatives. Deterministic, no model. | `src/density.zig` (+1 test-import line) | Unit tests; a flat AI doc scores low, apparatus doc scores high |
| E1 | **Seed corpus expansion.** Fix the no-op `wikilink-bad-arg` seed; teach `eval.zig` to take inline templates; mutate 2nap's 41 triples + 16 error cases into `eval/seeds.2nap.json`. | `src/eval.zig`, `eval/*` | Larger mock table; NO rows explained |
| T1 | **New templates** (`release-notes`, `reading-note`), shipped filters only, with shapes + sample data. Split across 2 agents if wanted. | `templates/<new>.*`, `templates/shapes/<new>.json`, `data/<new>.sample.json` | Renders md/gfm/textile clean; format_check sane |
| V0 | **Video pipeline smoke + storyboard.** vhs → ffmpeg → mp4 on dummy content; shot list mapped to SPEC's 8 beats; one `.tape` skeleton per beat against today's CLI. | `demo/` | Exported mp4; tapes run |
| (D4) | *Optional:* WordCraft/DesignCraft control-channel sensor (`document.inspect` → density signals). Needs the apps open locally. | `sensors/` | Baseline density on the sample doc |

## Wave 1 — after S0 merges (about 10 lanes)

| ID | Track | Needs | Owns |
|---|---|---|---|
| C1 | `knap_voice(template_id, data, tone)`: field-by-field rewrite, mock tones, Spark path via `backend.complete(.voice)` | S0 | `src/voice.zig`, `src/tools/voice.zig` |
| C2 | Structure hash (strip text leaves, hash skeleton) + `voice-eval`: same data × 3 tones → equal hashes, different strings | S0 (codes against C1's interface) | `src/structhash.zig`, `eval/voice/` |
| C3 | Tone presets + few-shot examples (`mild`/`spicy`/`feral`) | none (content) | `prompts/voice/*.md` |
| D2 | Ratchet loop: values-only mode fills apparatus data slots, scores via D1, reverts on score drop, bounded 4–8; `knap_density` + `knap_ratchet` tools | S0, D1 | `src/ratchet.zig`, `src/tools/density.zig`, `src/tools/ratchet.zig` |
| B2 | `knap_publish_check(doc_id)`: stage doc into frozen site → `boris check --fail-on-unlinked` → diagnostics; hallucinated-wikilink demo data | S0, B1 | `src/boris.zig`, `src/tools/publish_check.zig`, `data/*.hallucinated.json` |
| B3 | `boris_ask` / `boris_check` over the frozen artifact | S0, B1 | `src/borisrag.zig`, `src/tools/boris_*.zig` |
| M1 | Live backends: smoke Spark/Wonder/Baseten, fix reply parsing, record latency (and tokens only if metered) | S0, **API key** | `src/backend.zig` |
| M2 | Verifier slot, heuristic first (density delta + format_check + residual diags), decision-model hook | S0 | `src/verifier.zig` |
| K2 | dogbed: bump bundled k4o past #70 + parser-blocks, clean the stale `zig-0.17` branch; then bump the engine pin here | K1 merged | `~/dev/dogbed`, pin line in `scripts/engines.sh` |
| T2 | Upgrade `verdict`/`apparatus` to use `callout`, `set`, `??` | K1 merged + pin bump | `templates/verdict.*`, `templates/apparatus.*` |

## Wave 2 — integration, Oct 29–30 (about 5 lanes)

| ID | Track | Needs |
|---|---|---|
| I1 | End-to-end `make demo`: data → voice → render md/html/textile → format_check → publish_check → density | C1, B2, D2, K2 |
| I2 | Convergence table across mock/spark/wonder/baseten on the full corpus | M1, E1 |
| I3 | Density model matrix (values-only): which models fill apparatus slots | D2, M1 |
| I4 | Numbers card generator, measured values only (conformance delta, convergence, LOC, slice sizes) | K3, I2 |
| I5 | Freeze demo data; enforce the Oct 29 filter cut-line | K1/K2 status |

Feature freeze Oct 30 EOD. Oct 31 is buffer.

## Wave 3 — Nov 1–4

One agent per vhs tape (beats are independent), README + submission writeup,
final verification. Kdenlive assembly and portal submission are human steps.
Submit Nov 4 midday.

## Human-only blockers (do these in parallel with Wave 0)

- Claim Meta Model API credits, set `MODEL_API_KEY` (gates M1, I2, I3).
- Baseten request (verifier + `muse-spark-open-1026`).
- Rules check: video length/format, live vs recorded.
- Tell the other thread whether it or an Opus child owns K1.
- Probe Muse Code as the demo MCP client (optional).

## Critical paths

- S0 → C1 / D2 / B2 → I1 → freeze.
- K1 → K2 → T2 (HTML target + callouts in the demo).
- API key → M1 → I2 / I3 (the real numbers).

## File ownership hot map

| File | Wave 0 | Wave 1 |
|---|---|---|
| `src/tools.zig` registry, `src/main.zig` CLI table | S0 | captain (one-liners) |
| `src/backend.zig` | S0 | M1 |
| `src/eval.zig`, `eval/seeds*.json` | E1 | E1 (follow-ups) |
| `src/density.zig` | D1 | D2 |
| `templates/verdict.*`, `templates/apparatus.*` | — | T2 |
| `Makefile`, `scripts/engines.sh` | S0 | K2 (pin line only) |
| README / SPEC / GAMEPLAN | captain | captain |

## Child brief template

```
Track <ID>: <one line>.
Repo/worktree: <path>, branch feat/<id>-<slug> off main.
Read first: AGENTS.md, docs/PARALLEL-PLAN.md (your row), <files>.
You own: <files>. Do not edit anything else except <registry line>.
Engines: `make engines` then use the exported KNAP_K4O_PATH/KNAP_DOGBED_PATH.
Done when: <gate>. `make test && make eval` green.
Write notes to docs/tracks/<ID>.md. Open a PR (do not merge).
Last line: PR <url>, head <sha>, gates <state>.
```
