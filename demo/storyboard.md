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

Status key:

- **ready**: the tape renders the beat's final content today.
- **partial**: the tape renders today. Missing pieces are listed, with their commands commented in the tape.
- **placeholder**: the feature does not exist yet. The tape renders a slate for the beat's slot, and the intended commands are commented in the tape.

## Beat sheet

| # | Beat | Target | Last render | Tape | Depends on | Status |
|---|---|---|---|---|---|---|
| 1 | Cold open: the generic AI doc | 5s | 4.8s | `01-cold-open.tape` | fixture only; density score: D1 | ready |
| 2 | Ask for a verdict: model drafts data only | 20s | 20.8s | `02-verdict-data.tape` | main; `boris_ask`: B1+B3; live drafting: M1 + MCP client | partial |
| 3 | Seeded failure -> diagnostic -> repair -> clean | 25s | 23.0s | `03-repair.tape` | main (mock patches); real patches: M1 | ready |
| 4 | The doc | 30s | 29.2s | `04-the-doc.tape` | main; callouts: T2; HTML hero shot: K2; art: Muse Image (human) | partial |
| 4b | *(optional)* Density ratchet | 15s | 14.6s | `04b-density-ratchet.tape` | D1 + D2 | placeholder |
| 5 | The boris catch | 15s | 14.6s | `05-boris-catch.tape` | B1 + B2 | placeholder |
| 6 | Same template, mild vs feral | 20s | 19.5s | `06-voice.tape` | C1 + C2 + C3 | placeholder |
| 7 | One source -> md + apparatus + textile | 15s | 19.0s | `07-one-source.tape` | main; html: K2; one shared data file: T2/I5 | partial |
| 8 | Numbers card, measured only | 10s | 11.3s | `08-numbers.tape` | main (E1 corpora, K3 results); real table: M1/I2; card: I4 | partial |

**Runtime.** SPEC calls the demo "~2 min", but its per-beat targets add up to 2:20
(2:35 with beat 4b). The current rough cut of all 9 tapes runs 2:37; beat 7 is the
one tape well over its target (19.0s vs 15s). If the submission cap turns out to be
2:00, the cheapest cuts are beat 4 (30s to 20s), beat 2 (20s to 15s), and beat 6
(20s to 15s), which brings it to 2:05. Typing can also be sped up in Kdenlive. The video length limit is still
unconfirmed (see `docs/tracks/V0.md`).

**Engine pin risk.** K3 found that k4o `main` (181/188) dropped the gfm and textile
outputs. If the pin moves from the #71 lineage to `main`, beat 4 (gfm) and beat 7
(textile, which SPEC names explicitly) break. The pin decision (captain / K2) has to
account for the demo.

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
  freeze it (I5), and label it as model output. The density score overlay
  (`knap-mcp density`, expected low) is blocked on D1.

### 2. Ask for a verdict (20s): partial

- **On screen:** the six tool names the model can call (straight from the MCP server
  over stdio), the verdict template's field names, the drafted values, and `validate`
  returning ok. The point: the model sees shapes and writes values, and never sees layout.
- **Commands:**
  ```sh
  echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | knap-mcp | jq -r '.result.tools[].name'
  knap-mcp templates | jq -c '.templates[] | select(.id=="verdict") | .shape.fields | keys'
  jq '{verdict, take, blockers}' data/verdict.sample.json
  knap-mcp validate verdict -d data/verdict.sample.json | jq -c
  ```
- **Blocked:** "from real data (frozen boris artifact)" needs `boris_ask` (B1 + B3).
  "The model drafts" needs a real backend (M1) and a client. There is no CLI draft
  command; drafting happens in the MCP client (Muse Code if the probe works), which
  calls `knap_templates` and `knap_validate`. Record that session with OBS, or keep
  this tape and swap in the frozen drafted data file (I5).
- **Warning:** the server's `initialize` response is invalid JSON today (see V0.md).
  A real MCP client will fail at the handshake until that is fixed.

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
  knap-mcp repair verdict -d data/verdict.sample.json --target gfm --backend mock --out repaired.md | jq
  glow -p repaired.md
  ```
  `seeded/verdict.knap` is derived at take time by `demo_seed_unclosed_if` in
  `demo/lib/env.sh`, so it follows template edits.
- **Not byte-exact:** the mock closes the block at EOF, which moves one blank line, so
  E1's eval reports this seed as converged but not `exact`. The difference is not
  visible on screen.
- **Why this seed:** the unknown-filter seed also converges with mock, but the mock
  patch deletes `| head2` instead of fixing it to `| h2`, so "The case" loses its
  heading. Converged is not the same as correct, and that should not be on screen.
- **Open:** SPEC says "show diagnostic, patch, re-render visibly". The CLI reports
  steps but not the patch text, so the patch itself is not visible yet. Once M1 lands,
  try `--backend spark` on this seed; GAMEPLAN's fallback is to keep the mock take.

### 4. The doc (30s): partial

- **On screen:** the verdict rendered to gfm, paged in glow: H1, bold verdict and hot
  take, blockers list, receipts table, wikilinked sources with deep links, footnotes.
  glow hides the YAML frontmatter.
- **Commands:**
  ```sh
  knap-mcp render verdict -d data/verdict.sample.json --target gfm --out verdict.md | jq -c '{ok, target, bytes}'
  glow -p verdict.md     # Space for page 2
  ```
- **Missing:** callouts (T2, now that the pinned k4o has `callout`). The Muse Image
  art is a Kdenlive overlay (human). The better hero shot is dogbed HTML in a browser,
  which needs K2.
- **Visual bugs to fix before the final take:** the gfm `table` output has an empty
  header row, with "claim | evidence" rendered as a data row (the markdown target gets
  this right). The footnotes have no in-text references, and `format-check` flags them
  plus 2 bare URLs (T2). Keep `format-check` off screen until those are fixed.

### 4b. Density ratchet (15s, optional): placeholder

- **Why it exists:** the README pitch is the density ratchet, and SPEC's 8 beats
  predate it. Whether it gets a slot is the captain's call.
- **Intended:** `knap-mcp density` on the beat 1 doc (low), then `knap-mcp ratchet`
  showing the score climb per iteration with reverts on drops, then the final score
  (high). The command names are proposals; match whatever D1/D2 ship.

### 5. The boris catch (15s): placeholder

- **Intended:** render verdict from `data/verdict.hallucinated.json`, then run
  `knap-mcp publish-check <doc_id>`. An unresolved `[[wikilink]]` target comes back as
  a graph diagnostic with a non-zero exit, and the fixed data passes.
- **Blocked on:** B1 (frozen boris site) and B2 (`knap_publish_check`, hallucinated
  demo data). GAMEPLAN marks this beat cuttable if boris latency or the command shape
  is a problem.

### 6. Same template, mild vs feral (20s): placeholder

- **Intended:** `knap-mcp voice ... --tone mild` and `--tone feral`, render both,
  structure hashes equal on screen, then `diff` shows the strings differ.
- **Blocked on:** C1 (`knap_voice`), C2 (structure hash), C3 (tone presets).
  GAMEPLAN's fallback (hand-authored mild/feral data) still proves the invariant
  once C2's hash exists.

### 7. One source -> several views (15s): partial

- **On screen:** three renders from the CLI (verdict markdown, verdict textile,
  apparatus markdown), then `grep -c '<script'` printing 0 for each file.
- **Commands:**
  ```sh
  knap-mcp render verdict -d data/verdict.sample.json --target markdown --out verdict.md | jq -c '{ok, bytes}'
  knap-mcp render verdict -d data/verdict.sample.json --target textile --out verdict.textile | jq -c '{ok, bytes}'
  knap-mcp render apparatus -d data/apparatus.sample.json --target markdown --out apparatus.md | jq -c '{ok, bytes}'
  grep -c '<script' verdict.md verdict.textile apparatus.md
  ```
- **Missing:** `apparatus.html` (K2). The pinned dogbed bundles a pre-#70 k4o, so html
  fails on `yaml` (verdict) and `wikilink` (apparatus). "One source" also needs one
  data file behind both templates (T2/I5); today apparatus has its own sample file.

### 8. Numbers (10s): partial

- **On screen:** the mock eval summary on E1's 2nap corpus, K3's conformance lineage
  headline, and the server's line count. This tape is the provenance shot. The
  card itself is a still built by I4 and placed in Kdenlive.
- **Commands:**
  ```sh
  knap-mcp eval --corpus eval/seeds.2nap.json --backend mock | grep '^converged'
  jq -r .headline eval/conformance/results/summary-lineage.json
  cat $(find src/ -name '*.zig') | wc -l
  ```
- **Today's values (pinned k4o f97c5db, mock):** `seeds.2nap.json` converged 38/185,
  exact 4/35. `seeds.json` (demo templates only, not on tape) converged 6/22, exact 0/6. Conformance:
  `k4o base 15/188 → #70 43/188 → #71 48/188`. Per K3, quote this same-lineage line,
  never main → #70 → #71 as a progression.
- **Missing:** the real-backend runs (M1, I2); mock numbers prove the plumbing, not
  the model. "Calls x mean slice size" has no instrumentation, so it stays off the
  card. No token-cost numbers.

## Not on tape

- Title card and section slates: Muse Image stills, placed in Kdenlive.
- Voiceover: recorded by the human (see V0.md).
- MCP-client footage (Muse Code driving the server): OBS, if the probe works.
