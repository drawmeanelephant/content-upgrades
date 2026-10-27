# Gameplan — Meta Global AI Developer Hackathon
Oct 26 12pm ET → Nov 4 9pm ET · solo · indie track

Pitch line: **"AI can't do layout. So we don't let it."**
The unique space: everyone else fixes AI markdown by making it smaller.
We make markdown *maximal* — callouts, footnotes, tables, embeds — because the
formatting budget lives in the template, not in the model. Maximum formatting,
zero formatting risk.

> **Re-scoped 2026-10-27 (owner decision, #89):** no paid sponsor accounts.
> No Meta Model API key, no partner credits, no Muse Image, no Muse Code.
> The Meta model in the project is **Muse Wonder 1.0 via ACP** (`devin acp`,
> `devin-wonder` profile), always labeled "via ACP", never "direct API".
> Measured results are in `docs/tracks/LIVE.md`. Items below that needed a
> sponsor account are struck through, not deleted.

## Design principle
Everything that doesn't need the Meta Model API is built BEFORE kickoff.
The four pre-kickoff days are worth more than the four mid-hackathon days
because the unknowns all resolve on Oct 26 — don't spend kickoff week on
work that was always knowable.

---

## Phase 0 — Pre-production (Oct 22–25, NOW)

Needs no Meta API. All assets, no waste.

**D0 · Thu Oct 22**
- [ ] Application submitted (deadline Sun Oct 25 11:59pm ET, rolling cap)
- [ ] SPEC.md: tool contracts, subset grammar appendix (2nap subset = the
      published contract), repair-loop state machine (max 4 iters,
      non-convergence → best-effort + diagnostics, clean = 0 errors + 0 warnings)
- [ ] Decision locked: engines are k4o + dogbed only; 2nap corpus = eval origin

**D1 · Fri Oct 23**
- [ ] MCP skeleton (Zig, stdio JSON-RPC): initialize, tools/list, tools/call,
      **resources/list + resources/read** (the handles claim needs them),
      subprocess dispatch. Server is a dispatcher + repair/voice orchestration
      — budget ~800–1000 LOC, not 400.
- [ ] Dual-mode binary: `knap-mcp` (stdio) AND `knap-mcp render|validate|...`
      direct CLI subcommands. Judges without an MCP client can still drive it.
- [ ] Model-backend interface: `wonder | spark | verifier-slot | llama-baseten
      | mock`. Mock returns canned voice JSON — every downstream piece is
      buildable and testable now.
- [ ] Demo templates v1: extend dogbed's verdict / release-notes / reading-note
      + apparatus template (the citations page). Each ships a JSON-shape doc.

**D2 · Sat Oct 24**
- [ ] Repair-eval harness: mutate 2nap's 41 triples + 16 error cases through
      each pinned error class → seeded-breakage corpus + convergence scorer.
      This is the slide-number factory: "Spark fixes N/M seeded breaks."
- [ ] Boris artifact frozen: pre-built graph + search-index/RAG pack on a
      real dataset (craft-ai-integrations pass or boris's own docs).
      `boris_ask` reads the artifact, never live-indexes.
- [ ] format_check ruleset pinned (advisory only, ~8 rules):
      skipped heading levels, table-as-wall-of-text, unresolved footnote refs,
      empty callouts, raw-URL count, heading-count-to-length ratio,
      code fences unclosed, list-item-per-paragraph ratio.

**D3 · Sun Oct 25**
- [ ] Video pipeline smoke test END TO END on dummy content:
      vhs tape → ffmpeg trim → kdenlive assemble → exported mp4. Kills all
      tooling surprises before video week.
- [ ] Storyboard + shot list written (see Video section)
- [ ] Submit application if not already done — LAST DAY

## Phase 1 — Kickoff (Oct 26)
- [ ] Rules check: video length/format reqs, live-demo vs recorded,
      greenfield-code rules (MCP server + corpus + templates ARE new code;
      engines are pre-existing libraries — normal for indie)
- [ ] **Repo must be PUBLIC** (new hard rule, Oct 26 drop) — move
      knap-contest to a public GitHub repo; demo may only show work built
      during the event, so commit boundaries Oct 26 → Nov 4 must make
      new-vs-preexisting obvious.
- [ ] ~~Claim $150 Meta Model API credits (form → batch → Billing page; needs
      a card + temp pre-auth; set a spend limit). Deadline Nov 4 9pm ET.~~
      Dropped: no billing account (#85).
- [ ] ~~Request Baseten $100 + 2M TPM (capped at 2,000, reviewed by use case —
      submit the verifier-slot use case). Hackathon model id:
      `meta-models/muse-spark-open-1026`.~~ Dropped (#86).
- [x] ~~Wire real Spark behind the backend interface; smoke metering~~ Live
      model is Muse Wonder 1.0 via ACP; `knap-mcp smoke` meters it (LIVE.md).
- [x] **Run seeded-breakage eval against a live model TODAY**: the repair loop
      is the one externally-controlled centerpiece, so measure convergence
      before anything else depends on it. Done on Muse Wonder via ACP (22/22
      seeds, 167/167 2nap).
- [ ] Verify `boris check` command shape + latency on the staged site.
- [ ] ~~Probe Muse Image (cover/callout art), Muse Wonder (whatever it is),
      Muse Code (candidate: **the live demo MCP client**; the sponsor's own
      agent driving your server is a dogfood beat judges remember)~~ Dropped:
      Muse Image and Muse Code need a paid plan (#88, #102).
- [ ] ~~Check partner catalogs for an NLI/decision model (verifier slot)~~

## Phase 2 — Core build (Oct 27–29)

**Oct 27 — tools walk + filters start**: `knap_templates`, `knap_validate`,
`knap_render` (md/html/textile targets) live through MCP + CLI modes. Begin
the referential k4o filter set (footnote/fragment_link/wikilink first — the
apparatus depends on them; corpus cases exist for oracle-checking each).

**Oct 28 — the loop + filters land**: `knap_repair` (bounded, real Spark),
`knap_lint` (k4o lint passthrough), remaining referential filters
(callout/embed/image/yaml_property + set/??). Seeded-eval convergence
numbers by end of day.

**Oct 29 — data side + publish check**: `boris_ask`/`boris_check` on the
frozen artifact, `knap_publish_check` (stage doc → `boris check` → graph
diagnostics), `knap_format_check` (advisory). Full pipeline end-to-end.
**Filter cut-line: referential subset passing corpus cases by EOD or the
apparatus drops from demo templates.**

## Phase 3 — Voice + eval (Oct 30) — FREEZE
- [ ] Live voice pass (Muse Wonder via ACP): tone presets (mild → feral),
      voice lives in JSON data only. The "same template, two voices" proof runs clean.
- [ ] Convergence table final: seeded breaks × iterations → pass rate.
- [ ] Demo data frozen. **Feature freeze Oct 30 EOD** — Oct 31 is integration
      buffer, not feature time.

## Phase 4 — Video days (Nov 1–2) — dedicated, per plan

All-OSS pipeline:
- **vhs** (charmbracelet) — scripted terminal tapes; deterministic, re-recordable
- **OBS** — any live/pip segments; **Kdenlive** — assembly; **ffmpeg** — glue
- ~~**Muse Image** — title card / section slates; bonus Meta-tooling touch~~
  Title card and slates are hand-made or rendered by the pipeline (#102)
- Optional: submission page built by the pipeline itself (dogfooding)

Shot list (~2 min): see SPEC.md demo script — updated with boris-catch beat,
verifier escalation, clean-but-generic contrast, measured-only numbers card.
Demo client: dual-mode CLI via vhs (Muse Code dropped, #88).
Repair beat: seeded-broken template + REAL repair loop — deterministic input,
honest process, retake-able.

## Phase 5 — Buffer + ship (Nov 3–4)
- Nov 3: README, submission writeup, repo hygiene, second video pass if needed
- Nov 4: **submit by midday ET** — portal risk at deadline is real, don't
  gamble on the 9pm cutoff

---

## Variables → fallbacks (the contingency table)

| Variable | Decision point | Fallback |
|---|---|---|
| Meta Model API shape/metering | Oct 26 → **resolved Oct 27** | No key, no partner credits. Muse Wonder 1.0 via ACP (`devin-wonder`); other providers plug in through `scripts/providers.sh` |
| **Repair loop non-convergence** (demo centerpiece, externally controlled) | Oct 26 eval | Ship repair as recording + dual-mode CLI hands-on; live demo carries deterministic beats (validate/render/voice) |
| Spark voice quality | Oct 30 | Few-shot voice presets or human-authored data JSON; architecture story unchanged |
| Referential filters slip | Oct 29 cut-line | Apparatus drops from demo templates; demo runs on shipped filters |
| MCP client demo flakiness | Oct 29 | Dual-mode binary + vhs tapes of CLI mode |
| Video format reqs unknown | Oct 26 | Modular vhs segments reassemble at any length |
| Boris check latency/command | Oct 26–27 | Canned artifact is the floor; publish-check beat is cuttable |
| format_check reliability | Oct 29 | Advisory-only; cut entirely if it misfires |
| Greenfield-code rules | Oct 26 | MCP server + filters + corpus + templates are the new code |
| Muse Wonder unknown | Oct 26 → **resolved Oct 27** | It's the live model now, via ACP (LIVE.md) |

## The non-negotiables
1. The MCP server never grows engine logic (dogbed rule).
2. Repair loop is bounded; non-convergence is a feature (returns diagnostics).
3. Demo failure is pre-seeded — never rely on the model failing live.
4. Nothing ships after Oct 31 feature freeze except video + docs.
5. Submit Nov 4 midday, not 9pm.
