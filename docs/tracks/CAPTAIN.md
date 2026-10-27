# Captain notes

Loose ends the merge captain handled or is tracking across lanes.

## 2026-10-26: trailing `!` before a template footnote marker

`release-notes.knap` appends a footnote marker straight after a voice-eligible
value: `{{ h.what }}[^{{ h.note | kebab }}]`. A value ending in `!` makes the
bytes `![^...]`, which oliver reads as image syntax and leaves literal — the
footnote ref and its definition vanish from the html (markdown output is
unchanged; k4o's structhash markdown mode still counts the marker). Caught by
eval/voice: release-notes html hashed differently under feral.

Handled for now: the feral mock reply for `highlights[0].what` ends with
"somebody pinch me." instead of "pinch me!". The hazard is real for live
feral output, which loves a trailing `!`. Open follow-up: the voice guard
(src/voice.zig) could reject a value ending in `!` for fields a shape marks
as abutting a footnote marker, or the shape could forbid it per field.

## 2026-10-26: conformance is 187/188

K5 (#33) taught the runner k4o's warning lines. Sole failure:
`diagnostics/unknown-filter` (accepted: knap prints partial output on
fatal error, k4o buffers; k4o KNAP-FIDELITY.md). SPEC updated; the stale
"181/188" in demo/storyboard.md (line ~220) is deferred until I1 lands,
since I1 owns demo/ this wave.

## dogbed findings to route to a dogbed lane

- Verdict html drops the footnote definitions (found by C2).
- Frontmatter renders as `<hr/><p>` text in html (found by C2; dogbed
  renders what it is given, so the fix may be template-side).

## 2026-10-26: final-wave launch plan (ready, gated on MODEL_API_KEY)

State: everything through #40 merged. Both pins current (k4o `aeba163`,
dogbed `188ccac`), conformance 187/188, `make demo` runs all beats offline,
beats 4b/5/6 re-taped with shipped tools.

Remaining wave-2 lanes, in dependency order — briefs so a fresh thread can
fire them the moment the key lands:

- **M1 — live backends** (gate: `MODEL_API_KEY`). Owns `src/backend.zig`.
  Smoke Spark/Wonder/Baseten via `knap-mcp backends` + one `complete` per
  kind; fix reply parsing; record latency per backend (tokens only if
  metered). Gate: `make test`, eval unchanged on mock.
- **I2 — convergence table** (needs M1, E1). `make eval` across
  mock/spark/wonder/baseten on the full corpus; real rates replace mock
  rows in docs + storyboard beat 8. Parallel with I3.
- **I3 — density model matrix** (needs M1, D2). `ratchet-eval` per backend;
  which models fill apparatus slots, score climbs, rejection profile.
  Parallel with I2.
- **I4 — numbers card** (needs I2, K3). Measured-only card for beat 8:
  conformance delta, convergence, LOC, slice sizes.
- **I5 — freeze** (last, before Oct 30 EOD). Freeze demo data (swap live
  drafts for fixed files), enforce the Oct 29 filter cut-line.

Also open (parallel-safe, no key needed): `make demo` in CI (needs a boris
binary on the runner — package or vendor), stale-worktree cleanup, the
dogbed findings above, the trailing-`!` footnote hazard above.

Human blockers still open (PARALLEL-PLAN): `MODEL_API_KEY`, Baseten
request, video rules check, K1 ownership (other thread vs Opus child),
optional Muse Code MCP-client probe.

Wave 3 (Nov 1–4) is the actual swarm shape: **one agent per vhs tape**
(beats 1,2,3,4,4b,5,6,7,8 are independent files) + README/submission
writeup + final verification. Each tape agent owns one `demo/tapes/*.tape`
plus its storyboard section; shared-file conflicts are nil if beats stay
per-file. Pre-assign: beats 2/3 need M1 live output; beat 8 needs I4;
beat 4 needs the human hero shot + art. Kdenlive assembly and portal
submission stay human.
