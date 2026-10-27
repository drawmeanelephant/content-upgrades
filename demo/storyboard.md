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
| 1 | Cold open: the generic AI doc | 5s | 4.9s | `01-cold-open.tape` | fixture only | ready |
| 2 | Ask for a verdict: model drafts data only | 20s | 20.8s | `02-verdict-data.tape` | main; `boris_ask`: B3 (B1's `ask.sh` works now); live drafting: M1 + MCP client | partial |
| 3 | Seeded failure -> diagnostic -> repair -> clean | 25s | 23.2s | `03-repair.tape` | main (mock patches); real patches: M1 | ready |
| 4 | The doc | 30s | 29.4s | `04-the-doc.tape` | main; callouts: T2; HTML hero shot: human capture; art: Muse Image (human) | partial |
| 4b | *(optional)* Density ratchet | 15s | 15.2s | `04b-density-ratchet.tape` | D1 + D2 | ready (mock) |
| 5 | The boris catch | 15s | 16.7s | `05-boris-catch.tape` | B1 (boris-site, boris); `knap_publish_check`: B2 | ready |
| 6 | Same template, mild vs feral | 20s | 21.8s | `06-voice.tape` | C3 (mock replies), `knap_voice`: C1; structure hash: C2 | ready (mock) |
| 7 | One source -> md + html + apparatus | 15s | 18.6s | `07-one-source.tape` | main; oliver target: P1; one shared data file: cut (T2/I5 deferred) | partial |
| 8 | Numbers card, measured only | 10s | 12.0s | `08-numbers.tape` | main (E1 corpora, K3 results); real table: M1/I2; card: I4 | partial |

**Runtime.** SPEC calls the demo "~2 min", but its per-beat targets add up to 2:20
(2:35 with beat 4b). The current rough cut of all 9 tapes runs 2:43 (2:27 without
4b); beat 7 is the one tape well over its target (18.6s vs 15s). If the submission
cap turns out to be 2:00, drop 4b and cut beat 4 (30s to 20s), beat 2 (20s to 15s),
and beat 6 (20s to 15s): that brings the rendered beats to about 2:03, and trimming
beat 7 to its target gets under 2:00. Typing can also be sped up in Kdenlive. The
video length limit is still unconfirmed (see `docs/tracks/V0.md`).

**Engines and targets.** Tapes take the engine pins from `scripts/engines.sh`, now k4o
main `aeba163` and dogbed main `188ccac`. That k4o has no gfm or textile output, so
the tapes use only markdown and html. SPEC's beat 7 now names `verdict.oliver`; on
screen it is verdict.html — oliver renders byte-identical to markdown for this
template, so html is what makes "several views" visible. The k4o main markdown
target emits pipe tables, so glow renders the receipts table properly.

**Retakes.** Inputs are fixed, so every take prints the same text. The one exception is
the `doc_id` handle in beat 3's repair result, which embeds a nanosecond timestamp.

## Beats

### 1. Cold open (5s): ready

- **On screen:** a flat AI-style review of AcmeDB rendered by glow. It is clean
  markdown with no callouts, footnotes, deep links, or table, and the voice is ironed
  out. No typing; the doc is already up when the clip starts.
- **Commands (hidden):** `glow fixtures/generic-ai-doc.md`
- **Depends on:** `demo/fixtures/generic-ai-doc.md`, a hand-written stand-in for flat model output.
- **Open:** once M1 lands, replace the fixture with a real flat output from a model,
  freeze it (I5), and label it as model output. The density score overlay is no
  longer blocked: `knap-mcp density <file>` takes a file path, and the fixture
  scores 3.7 on density/1 — an overlay could go on screen now (human, Kdenlive).

### 2. Ask for a verdict (20s): partial

- **On screen:** the tool names the model can call (`tools/list`, straight from the
  MCP server over stdio), the verdict template's field names, the drafted values, and
  `validate` returning ok. The point: the model sees shapes and writes values, and
  never sees layout.
- **Commands:**
  ```sh
  echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | knap-mcp | jq -r '.result.tools[].name'
  knap-mcp templates | jq -c '.templates[] | select(.id=="verdict") | .shape.fields | keys'
  jq '{verdict, take, blockers}' data/verdict.sample.json
  knap-mcp validate verdict -d data/verdict.sample.json | jq -c
  ```
- **Blocked:** "from real data (frozen boris artifact)" needs `boris_ask` (B3). B1's
  reference query works today and is commented in the tape:
  `boris-site/ask.sh -k 3 'AcmeDB backups' | jq -r '[.score, .title] | @tsv'` (top hits:
  "AcmeDB docs — backups", the "no managed backups" claim). It adds about 4s to a beat
  that is already at its target, so whether to show it before B3 lands is a timing call.
  "The model drafts" needs a real backend (M1) and a client. There is no CLI draft
  command; drafting happens in the MCP client (Muse Code if the probe works), which
  calls `knap_templates` and `knap_validate`. Record that session with OBS, or keep
  this tape and swap in the frozen drafted data file (I5).

### 3. Seeded failure -> repair (25s): ready

- **On screen:** `diff` shows the seeded break, one `{% endif %}` removed from the
  shipped verdict template. `validate` returns the pinned k4o diagnostic
  (`syntax error`, line 1, `unclosed if block`). One `repair` call returns
  `converged: true`, `iterations: 1`, and the step it took. The clip ends on the
  repaired doc in glow's pager.
- **Commands:**
  ```sh
  diff templates/verdict.knap seeded/verdict.knap
  export KNAP_TEMPLATES_DIR=seeded
  knap-mcp validate verdict -d data/verdict.sample.json | jq '.diagnostics[0]'
  knap-mcp repair verdict -d data/verdict.sample.json --target markdown --backend mock --out repaired.md | jq
  glow -p repaired.md
  ```
  `seeded/verdict.knap` is derived at take time by `demo_seed_unclosed_if` in
  `demo/lib/env.sh`, so it follows template edits.
- **Template not byte-exact:** the mock closes the block at EOF, so the repaired
  template differs from the shipped one and E1's eval does not count this seed as
  `exact`. On k4o `aeba163` the repaired doc is byte-identical to a clean render
  (checked with `diff`), so nothing differs on screen.
- **Why this seed:** the unknown-filter seed also converges with mock, but the mock
  patch deletes `| head2` instead of fixing it to `| h2`, so "The case" loses its
  heading. Converged is not the same as correct, and that should not be on screen.
- **Open:** SPEC says "show diagnostic, patch, re-render visibly". The CLI reports
  steps but not the patch text, so the patch itself is not visible yet. Once M1 lands,
  try `--backend spark` on this seed; GAMEPLAN's fallback is to keep the mock take.

### 4. The doc (30s): partial

- **On screen:** the verdict rendered to markdown, paged in glow: H1, bold verdict and hot
  take, blockers list, receipts table, wikilinked sources with deep links, footnotes.
  glow hides the YAML frontmatter.
- **Commands:**
  ```sh
  knap-mcp render verdict -d data/verdict.sample.json --target markdown --out verdict.md | jq -c '{ok, target, bytes}'
  glow -p verdict.md     # Space for page 2
  ```
- **Missing:** callouts (T2, now that the pinned k4o has `callout`). The Muse Image
  art is a Kdenlive overlay (human). The better hero shot is dogbed HTML in a browser.
  The pinned dogbed renders both templates to html now, but nobody has styled or
  captured it (human, OBS or a headless screenshot).
- **Visual state, verified on main:** the receipts table renders a real header row
  (`| Claim | Evidence | Source |`), receipts with a `note` carry in-text footnote
  refs (`[^benchmark]`, `[^backup-gap]`), and `format-check` returns zero warnings
  on the sample render — it can go on screen.

### 4b. Density ratchet (15s, optional): ready (mock)

- **Why it exists:** the README pitch is the density ratchet, and SPEC's 8 beats
  predate it. Whether it gets a slot is the captain's call.
- **On screen:** the required-fields-only doc renders, then one `ratchet` call,
  then the accepted steps (slot + gain per iteration) and the score summary:
  start 44.5 -> final 71.3 against a 71.2 ceiling, 4/8 slots filled, stop
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
  the tape runs — and verdict's shape carries no ratchet slots yet.
- **Missing:** only a live-backend run (M1).

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

### 6. Same template, mild vs feral (20s): ready (mock)

- **On screen:** two real `knap-mcp voice` passes (`--tone mild`, `--tone feral`,
  mock backend), the two renders, `structhash` printing the same hash for both —
  the falsifiable proof that voice touched only values — then `diff` showing six
  changed lines: title + verdict in frontmatter and body, the summary, and the
  bottom line. Everything else (table, sources, footnotes) is identical; both
  docs are 69 lines (wc stays off screen — the hash is the stronger claim).
- **Commands:**
  ```sh
  knap-mcp voice verdict -d v0.json --tone mild --backend mock | tee mild.json | jq -c '{tone,changed}'
  knap-mcp voice verdict -d v0.json --tone feral --backend mock | tee feral.json | jq -c '{tone,changed}'
  for t in mild feral; do jq .data $t.json | knap-mcp render verdict -d - --out $t.md | jq -c '{ok,bytes}'; done
  knap-mcp structhash mild.md feral.md
  diff mild.md feral.md
  ```
  `v0.json` is a copy of `data/verdict.sample.json` made in the hidden preamble
  to keep the typed lines under the frame width. The mock backend returns C3's
  canned replies (`prompts/voice/mock/<tone>.jsonl`), the same data
  `demo_seed_voice` used to apply, so the take is fixed.
- **Missing:** only a live-backend voice pass (M1).

### 7. One source -> several views (15s): partial

- **On screen:** three renders from the CLI (verdict markdown, verdict html, apparatus
  html), then `grep -c '<script'` printing 0 for each file.
- **Commands:**
  ```sh
  knap-mcp render verdict -d data/verdict.sample.json --target markdown --out verdict.md | jq -c '{ok, bytes}'
  knap-mcp render verdict -d data/verdict.sample.json --target html --out verdict.html | jq -c '{ok, bytes}'
  knap-mcp render apparatus -d data/apparatus.sample.json --target html --out apparatus.html | jq -c '{ok, bytes}'
  grep -c '<script' verdict.md verdict.html apparatus.html
  ```
- **Changed from SPEC:** SPEC's beat 7 names `verdict.oliver`; the tape shows
  verdict.html instead, because oliver renders byte-identical to markdown for
  this template and html makes the second view visible.
- **Cut:** "one source" — one data file behind both templates (T2/I5) is
  deferred. apparatus keeps its own `data/apparatus.sample.json`; the take
  shows verdict and apparatus rendered from their own sample files.

### 8. Numbers (10s): partial

- **On screen:** the mock eval summary on E1's 2nap corpus, K3's conformance totals
  for the pinned k4o, and the server's line count. This tape is the provenance shot. The
  card itself is a still built by I4 and placed in Kdenlive.
- **Commands:**
  ```sh
  knap-mcp eval --corpus eval/seeds.2nap.json --backend mock 2>/dev/null | grep '^converged'
  jq -c '{label, totals}' eval/conformance/results/k4o-main-aeba163.json
  cat $(find src/ -name '*.zig') | wc -l
  ```
- **Today's values (pinned k4o aeba163, dogbed 188ccac, mock):** `seeds.2nap.json`
  converged 120/167, exact 58/115, 0 no-op seeds. `seeds.json` (demo templates only,
  not on tape) converged 12/22, exact 4/12, 0 no-op seeds. Conformance: k4o main
  187/188 (1 fail: the accepted `diagnostics/unknown-filter` buffered-output
  difference, 0 unsupported).
  Per K3, never quote main → #70 → #71 as a progression. Under this k4o, three 2nap
  base templates don't render (no `codeblock` or `numbered` filter), and their 12
  seeds plus the no-op seeds each print a warning on stderr, so the tape sends stderr
  to `/dev/null`.
- **Missing:** the real-backend runs (M1, I2); mock numbers prove the plumbing, not
  the model. "Calls x mean slice size" has no instrumentation, so it stays off the
  card. No token-cost numbers.

## Not on tape

- Title card and section slates: Muse Image stills, placed in Kdenlive.
- Voiceover: recorded by the human (see V0.md).
- MCP-client footage (Muse Code driving the server): OBS, if the probe works.
