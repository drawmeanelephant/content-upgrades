# Storyboard: the ~2-minute demo

This is the shot list for the demo script in `docs/SPEC.md` ("Demo script, ~2 min").
Each beat is one vhs tape in `demo/tapes/`. Every tape uses the pinned engines, the
mock backend, fixed data, and the shared terminal look in `demo/tapes/_settings.tape`
(1920x1080, Menlo 24, Catppuccin Mocha).

```sh
demo/build.sh tapes          # render every beat -> demo/out/tapes/NN-*.mp4
demo/build.sh tapes 03       # re-record one beat
demo/build.sh rough          # all rendered beats -> demo/out/rough-cut.mp4 (timing reference)
demo/build.sh smoke          # toolchain smoke test -> demo/out/smoke.mp4
```

`make demo` (`demo/run.sh`) runs every beat below as one scripted terminal run on
the mock backend, with no vhs and no network. It uses the same shipped commands
the tapes now run (`voice`, `structhash`, `publish-check`, `density`, `ratchet`)
and writes a normalized transcript and the beat artifacts to `demo/out/demo/`
(see `docs/tracks/I1.md`). Use it as the per-beat reference text when
re-recording a tape.

Status key:

- **ready**: the tape renders the beat's final content today.
- **partial**: the tape renders today. Missing pieces are listed, with their commands commented in the tape.
- **placeholder**: the feature does not exist yet. The tape renders a slate for the beat's slot, and the intended commands are commented in the tape.

## Beat sheet

| # | Beat | Target | Last render | Tape | Depends on | Status |
|---|---|---|---|---|---|---|
| 1 | Cold open: the generic AI doc (density/3 24.7) | 5s | 4.9s | `01-cold-open.tape` | fixture only | ready |
| 2 | Ask for a verdict: model drafts data only | 20s | 20.7s | `02-verdict-data.tape` | frozen drafted take (I5); `boris_ask` (B3) | ready |
| 3 | Seeded failure -> diagnostic -> repair -> clean | 25s | 25.0s | `03-repair.tape` | frozen live take (I5); seed + diag: main | ready |
| 4 | The doc | 30s | 28.9s | `04-the-doc.tape` | main; hero still: `demo/hero/`; art overlay: #102 (human) | ready |
| 4b | *(optional)* Density ratchet | 15s | 15.2s | `04b-density-ratchet.tape` | D1 + D2 | ready (mock) |
| 5 | The boris catch | 15s | 16.7s | `05-boris-catch.tape` | B1 (boris-site, boris); `knap_publish_check`: B2 | ready |
| 6 | Same template, mild vs feral | 20s | 19.7s | `06-voice.tape` | frozen live voice takes (I5); structure hash: C2 | ready |
| 7 | One source -> md + html + apparatus | 15s | 15.2s | `07-one-source.tape` | main; oliver target: P1; one shared data file: cut (T2/I5 deferred) | ready |
| 8 | Numbers card, measured only | 10s | 10.5s | `08-numbers.tape` | main (E1 corpora, K3 results); live takes: I2/I3; card: I4 | ready |

**Runtime.** SPEC calls the demo "~2 min", but its per-beat targets add up to 2:20
(2:35 with beat 4b). The current render of all 9 tapes runs 2:37 (2:22 without
4b); beat 5 is the tape furthest over its target (16.7s vs 15s), and beat 7 sits
on its 15s target at 15.2s. If the submission cap turns out to be 2:00, drop 4b
and cut beat 4 (30s to 20s), beat 2 (20s to 15s), and beat 6 (20s to 15s): that
brings the rendered beats to about 2:02, and trimming the three tapes still
over their targets (5, 7 and 8) lands just under 2:00. Typing can also be sped
up in Kdenlive. The video length limit is still unconfirmed (see
`docs/tracks/V0.md`).

**Engines and targets.** Tapes take the engine pins from `scripts/engines.sh`, now k4o
main `aeba163` and dogbed main `d96b125`. That k4o has no gfm or textile output, so
the tapes use only markdown and html. SPEC's beat 7 now names `verdict.oliver`; on
screen it is verdict.html — oliver renders byte-identical to markdown for this
template, so html is what makes "several views" visible. The k4o main markdown
target emits pipe tables, so glow renders the receipts table properly.

**Retakes.** Inputs are fixed, so every take prints the same text. Beat 3's repair
result is a frozen file (I5), so even its `doc_id` handle no longer varies.

## Beats

### 1. Cold open (5s): ready

- **On screen:** the frozen real flat doc — a verbatim model reply
  (`gpt-5-5-none` via ACP (devin), provenance in
  `demo/fixtures/generic-ai-doc.provenance.json`) rendered by glow, with a dim
  caption row labeling it as model output. It is clean markdown with no callouts,
  footnotes, deep links, or table, and the voice is ironed out. No typing; the doc
  and its label are already up when the clip starts.
- **Commands (hidden):** `glow fixtures/generic-ai-doc.md` with a dim `printf`
  caption row chained on the same line: `model output: gpt-5-5-none via ACP (devin)`.
- **Depends on:** `demo/fixtures/generic-ai-doc.md`, the frozen real flat output
  (I5/#140; density/3 24.7, 479 words — the number for the Kdenlive overlay).

### 2. Ask for a verdict (20s): ready

- **On screen:** the tool names the model can call (`tools/list`, straight from the
  MCP server over stdio), the verdict template's field names, `boris_ask` hits from
  the frozen site artifact, the frozen draft's `verdict`/`take`/`blockers` labeled
  Muse Wonder 1.0 via ACP (devin, low thinking), and `validate` returning ok. The
  point: the model sees shapes and writes values, and never sees layout.
- **Commands:**
  ```sh
  echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | knap-mcp | jq -r '.result.tools[].name'
  knap-mcp templates | jq -r '.templates[] | select(.id=="verdict") | .shape.fields | keys[]'
  knap-mcp boris-ask 'AcmeDB backups' --limit 3 | jq -c '.results[] | {score,title}'
  jq -r .label frozen/provenance.json
  jq '{verdict, take, blockers}' frozen/02-verdict.drafted.json
  knap-mcp validate verdict -d frozen/02-verdict.drafted.json | jq -c
  ```
  `frozen/` is a symlink to `demo/frozen` made in the hidden preamble, so on-screen
  paths name the frozen inputs. The shape prints `keys[]` one field per line — the
  one-line `keys` array is 174 chars, over the 121-column frame.
- **Frozen inputs (I5):** `demo/frozen/02-verdict.drafted.json` is the model's
  drafted data (one take, no retakes); `demo/frozen/provenance.json` supplies the
  on-screen label. `boris_ask` reads the frozen site artifact offline.
- **Continuity (I5 cut list):** the draft reaches its own verdict (`"skip it"`) from
  the sources alone; beat 4 renders the curated `data/verdict.sample.json`
  (`"give a shit"`). The beat shows only that the model's draft validates against
  the shape — nothing implies beat 4's doc is rendered from this draft.
- **Open:** none — the frozen-draft portion stays; #88 was closed won't-do.

### 3. Seeded failure -> repair (25s): ready

- **On screen:** `diff` shows the seeded break, one `{% endif %}` removed from the
  shipped verdict template. `validate` returns the pinned k4o diagnostic
  (`syntax error`, line 29, `unclosed if block`). The repair shown is the frozen
  live take (I5), labeled `Muse Wonder 1.0 via ACP (devin)`: `converged: true`,
  `iterations: 1`. `steps[0].patch` is shown as the diff it makes against the
  seeded region it replaces — the missing `{% endif %}` comes back, folded onto
  the `{% if %}` line. The clip ends on the frozen repaired doc in glow's pager.
- **Commands:**
  ```sh
  diff templates/verdict.knap seeded/verdict.knap
  KNAP_TEMPLATES_DIR=seeded knap-mcp validate verdict -d data/verdict.sample.json | jq -c '.diagnostics[0]'
  echo '# frozen live take: Muse Wonder 1.0 via ACP (devin)'
  jq -c '{converged,iterations,step:.steps[0]|{line,detail}}' repair.json
  diff <(tail -n +$RS seeded/verdict.knap) <(jq -j '.steps[0].patch' repair.json)
  glow -p repaired.md
  ```
  `seeded/verdict.knap` is derived at take time by `demo_seed_unclosed_if` in
  `demo/lib/env.sh`, so it follows template edits. `repair.json` /
  `repaired.md` are copies of `demo/frozen/03-repair.json` /
  `demo/frozen/03-repaired.md` made in the hidden preamble; `RS` is
  `steps[0].region_start` (29 on the frozen take).
- **Patch display:** `jq '.steps[0] | {line, detail, patch}'` prints the patch
  as one JSON-escaped line (~2 KB), far past the 121-column frame, so the tape
  diffs the same `steps[0].patch` against the seeded region it replaces instead:
  `1c1`, the `{% endif %}` restored. `jq -j` keeps jq from appending a newline
  the model did not emit.
- **Template not byte-exact:** the live patch folds `{% if subject %}` and its
  `{% endif %}` onto one line, so the patched template differs from the shipped
  one and E1's eval does not count this seed as `exact`. On k4o `aeba163` the
  repaired doc is byte-identical to a clean render (checked with `cmp` in
  `demo/run.sh`), so nothing differs on screen.
- **Why this seed:** the unknown-filter seed also converges with mock, but the mock
  patch deletes `| head2` instead of fixing it to `| h2`, so "The case" loses its
  heading. Converged is not the same as correct, and that should not be on screen.
- **Open:** none — the converging live take the freeze issue captured is what
  SPEC asks for: diagnostic, patch, re-render, all visible.

### 4. The doc (30s): ready

- **On screen:** the verdict rendered to markdown, paged in glow: H1, bold verdict and hot
  take, the quote and danger callouts, receipts table, wikilinked sources with deep
  links, footnotes, and the folded warning and info callouts on page 2.
  glow hides the YAML frontmatter.
- **Commands:**
  ```sh
  knap-mcp render verdict -d data/verdict.sample.json --target markdown --out verdict.md | jq -c '{ok, target, bytes}'
  glow -p verdict.md     # Space for page 2
  ```
- **Hero still:** `demo/hero/verdict.png` (1920x1080) — the pinned dogbed's html
  render wrapped in `demo/hero/style.css` (Catppuccin Mocha, zero JavaScript;
  `demo/hero/build.sh` re-captures it with headless Chrome and refuses to ship a
  page containing any). Callouts, the receipts table and the footnotes sit above
  the fold; the empty right third is the slot for the art overlay (#102 —
  human, placed in Kdenlive).

### 4b. Density ratchet (15s, optional): ready (mock)

- **Why it exists:** the README pitch is the density ratchet, and SPEC's 8 beats
  predate it. Whether it gets a slot is the captain's call.
- **On screen:** the required-fields-only doc renders, then one `ratchet` call,
  then the accepted steps (slot + gain per iteration) and the score summary:
  start 38.0 -> final 81.8 against a 81.8 ceiling, 5/13 slots filled, stop
  reason `ceiling`. Deterministic on the mock backend.
- **Commands:**
  ```sh
  knap-mcp ratchet release-notes -d r0.json --backend mock | tee ratchet.json | jq -c '{ok,stop}'
  jq -c '.steps[] | {slot, gain, accepted}' ratchet.json
  jq -c '{score, slot_fill, stop}' ratchet.json
  ```
  `r0.json` is a copy of `data/release-notes.min.json` made in the hidden
  preamble to keep the typed line under the frame width. The plan proposed
  `verdict` and `data/verdict.min.json` ships now, but the README's ratchet
  example is `release-notes` + `data/release-notes.min.json`, which is what
  the tape runs.
- **Missing:** only a live take — the `devin-wonder` ACP profile
  (`--backend acp`, `KNAP_ACP_AGENT='devin acp --model muse-wonder-1-0-low'`;
  `scripts/providers.sh`).

### 5. The boris catch (15s): ready

- **On screen:** a verdict with one invented source renders with `ok: true`.
  `knap-mcp publish-check` stages the doc into a copy of the frozen site and runs
  `boris validate`: it fails (exit 1) with
  `EREFERENCEMISSING: wiki-link target "acmedb-soc-2-audit-report" not found in the page graph`
  naming `[[AcmeDB SOC 2 audit report]]`. Re-rendered from the real sample data,
  the same check returns `{"ok":true,...}` with all links resolved (exit 0).
- **Commands:**
  ```sh
  knap-mcp render verdict -d bad.json | tee v1.json | jq -c '{ok,bytes}'
  knap-mcp publish-check $(jq -r .doc_id v1.json) | jq -c '.diagnostics[]'
  v2=$(knap-mcp render verdict -d good.json | jq -r .doc_id)
  knap-mcp publish-check $v2 | jq -c '{ok,links,pages}'
  ```
  `bad.json` / `good.json` are copies made in the hidden preamble to keep the
  typed lines short. `bad.json` is `seeded/verdict.hallucinated.json`, derived
  at take time by `demo_seed_hallucinated_source` in `demo/lib/env.sh`: the
  sample data plus the same invented source that `boris-site/selftest.sh`
  injects. `good.json` is `data/verdict.sample.json`. `knap_publish_check` (B2)
  is the shipped tool; B1's `stage-check.sh` remains as the reference behavior
  in `boris-site/`. Needs `boris` on `PATH` (the tape `Require`s it).
- **Missing:** nothing for the mock take.

### 6. Same template, mild vs feral (20s): ready

- **On screen:** the two frozen live `knap_voice` results labeled
  `Muse Wonder 1.0 via ACP (devin, low thinking)` (`{tone,changed}` — 8 fields
  rewritten per take, 0 rejected), then three offline renders — the curated
  sample plus both frozen takes — `structhash` printing `6a738a8906ac2273`
  for all three, and `diff` showing six hunks: title + verdict in frontmatter
  and body, the summary, and the bottom line. Everything else (table, sources,
  footnotes) is identical; all three docs are 70 lines.
- **Commands:**
  ```sh
  echo '# voice: Muse Wonder 1.0 via ACP (devin, low thinking)'; jq -c '{tone,changed}' v.{mild,feral}.json
  for t in orig mild feral; do knap-mcp render verdict -d d.$t.json --out $t.md | jq -c '{ok,bytes}'; done
  knap-mcp structhash orig.md mild.md feral.md
  diff mild.md feral.md | fold -s -w 118
  ```
  `v.<tone>.json` are copies of `demo/frozen/06-voice-<tone>.json` (the recorded
  `knap_voice` results) and `d.<tone>.json` their `.data`; `d.orig.json` is a
  copy of `data/verdict.sample.json`. All made in the hidden preamble to keep
  the typed lines under the frame width. `fold` wraps the feral summary line
  (215 columns) inside the 121-column frame. Nothing on tape calls a live
  model; the structhash line must print the frozen record's hash or the take
  stops (demo/frozen/06-structhash.txt).
- **Missing:** nothing for this take.

### 7. One source -> several views (15s): ready

- **On screen:** one typed line loops the verdict renders (markdown, oliver,
  html), one more renders apparatus html, then `grep -c '<script'` prints
  `:0` for `verdict.md`, `verdict.oliver`, `verdict.html` and
  `apparatus.html` — SPEC's list plus the html view, zero JavaScript.
- **Commands:**
  ```sh
  for t in markdown oliver html; do knap-mcp render verdict -d v --target $t --out verdict.$t | jq -c '{ok}'; done
  knap-mcp render apparatus -d a --target html --out apparatus.html | jq -c '{ok}'
  mv verdict.markdown verdict.md; grep -c '<script' verdict.md verdict.oliver verdict.html apparatus.html
  ```
  `v` / `a` are copies of `data/verdict.sample.json` / `data/apparatus.sample.json`
  made in the hidden preamble, and the `mv` gives the markdown render its SPEC
  file name — both keep every typed line under the 121-column frame.
- **Changed from SPEC:** nothing — `verdict.oliver` is on screen now. Oliver
  renders byte-identical to markdown for this template, so html is still the
  view that makes "several views" visible.
- **Cut:** "one source" — one data file behind both templates (T2/I5) is
  deferred. apparatus keeps its own `data/apparatus.sample.json`; the take
  shows verdict and apparatus rendered from their own sample files.

### 8. Numbers (10s): ready

- **On screen:** the provenance for every number on the card: the frozen live
  repair runs (acp: devin summarizer + Muse Wonder 1.0 via ACP (devin), I2) on
  both corpora, then `demo/card/build.sh` deriving and printing each card value
  with its source — the mock control eval, the density/2 ratchet tally (I3),
  the pinned-k4o conformance, the server LOC — and writing
  `demo/card/numbers.json` + `numbers.png`. The card itself is a still placed
  in Kdenlive.
- **Commands:**
  ```sh
  grep '^converged' n/s22.out n/w22.out n/s2.out n/w2.out
  card/build.sh
  jq -r '.columns[].label' card/numbers.json
  ```
  `n/*.out` are symlinks to the I2 repair runs (`eval/results/live/acp-seeds*.out`,
  `eval/results/live/devin-wonder/repair-seeds*.out`) made in the hidden
  preamble; `card` links `demo/card/`.
- **Card:** `demo/card/build.sh` writes `numbers.json` (every value carries its
  source path plus the engine/scorer version) and renders `numbers.png`
  (1920x1080) through `card.html` and a headless Chrome screenshot (this
  ffmpeg has no drawtext, V0.md finding 4). Columns: mock (control),
  acp: devin summarizer, Muse Wonder 1.0 via ACP (devin). Rows: repair
  converged on both corpora, the density/2 ratchet cases-ok tally and best
  climb, calls × mean slice for both evals, k4o conformance, server LOC.
  Conformance shows 187/188 on pin aeba163 next to the base → #70 → #71
  lineage line — never a main → #70 → #71 progression (K3). ACP columns are
  model plus agent; no token-cost numbers (the ~13.5k-token agent system
  prompt per call, LIVE.md finding 3).
- **Values on this render (pinned k4o aeba163, dogbed d96b125):** repair
  converged — mock 12/22 + 120/167, summarizer 22/22 + 166/167, Wonder
  22/22 + 167/167. Ratchet cases ok — mock 9/9, summarizer 3/9, Wonder 3/9
  (the misses are measured model shortfall against the mock-tuned bar, not
  harness breakage). Conformance 187/188 (the one accepted
  `diagnostics/unknown-filter` buffered-output diff, 0 unsupported). Server
  22,393 lines of Zig.

## Not on tape

- Title card and section slates: hand-made or pipeline-rendered stills
  (#102), placed in Kdenlive.
- Voiceover: recorded by the human (see V0.md).
