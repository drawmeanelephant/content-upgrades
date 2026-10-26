# SPEC — knap-mcp

AI that barfs out perfect, sassy markdown. One Zig binary. Zero JavaScript.

Pitch line: **AI can't do layout. So we don't let it.**
Precisely: the model never *authors* or *chooses* layout. Templates are fixed,
server-side, human-authored. Voice writes JSON values; repair patches
fragments that the compiler must re-verify. **Nothing ships unverified.**
Second line: **sourcing is what builds but isn't published.**

## The product, concretely

The taste-verdict blog: link in → sassy "should you give a shit" verdict out,
with the full citation apparatus nobody renders — endnotes, deep-linked
citations, footnotes that can't dangle, link clouds, and a separate
citations page from the same data.

The research pass already generates every source, quote, and claim — it dies
in the model's context. We persist it as data and render it as apparatus.
The research is already paid for; publish it.

One `data.json` → **document views**, not just format targets:
`verdict.html` + `apparatus.html` (the second-page citations) + `verdict.md`
+ `verdict.oliver`. Same source, separate artifacts — the apparatus is a first-class
page, not an afterthought.

Data sketch:
```json
{
  "verdict": {"subject": "...", "gaf": "high", "take": "..."},
  "claims": [{"text": "...", "source_ids": ["s1"], "confidence": "..."}],
  "sources": [{"id": "s1", "title": "...", "url": "...",
    "accessed": "...", "quotes": [{"text": "...", "used_for": "..."}],
    "reliability": "...", "gaf": "low"}]
}
```

## Architecture

Three jobs, three owners, one invariant per owner:

| Job | Owner | Invariant |
|---|---|---|
| WHAT to say (facts) | boris | Validated graph artifact; cited, deterministic, never regenerated mid-render |
| HOW it looks (layout) | knap template | Rendered by k4o/dogbed only; the model never sees it |
| HOW it sounds (voice) | Muse models | Writes JSON *values* only; cannot touch structure |
| Is it right (validation) | boris + engines | Native binaries, sub-100ms cycles — never a model call where a compiler check exists |

Boris is a **downstream-consumer** relationship only: the MCP calls existing
boris CLI surfaces (`check` — graph-health policy incl. unlinked-reference
detection; `search-index`/`source-rag` artifacts). Nothing upstream changes;
boris's own rules make this the sanctioned usage pattern. Command shape and
latency measured against the real binary (boris 0.8.2, Oct 26): `boris check`
on a staged doc is about 3–5 ms and the end-to-end staged check about 40–50
ms, so layer 3 joins the sub-100ms claim.

## Validation stack (layers 1–3 native-fast; layer 4 is a model call)

1. **k4o/dogbed render** — template correctness, line/col diagnostics.
2. **knap_format_check** — document structure, advisory.
3. **boris check via `knap_publish_check`** — the emitted doc *in site-graph
   context*: do wikilink targets resolve? does frontmatter parse? does the
   apparatus page fit the site model? References become graph lookups —
   hallucinated links caught pre-publish, reported as diagnostics. (Claim
   scope: "caught pre-publish," not "enforced at render time" — the graph is
   a frozen validated artifact, not a live database.)
4. **semantic verification** — a small NLI/decision classifier (Jev-like;
   served via Baseten/Modal/Fireworks partner credits) checks claim↔quote
   entailment per citation. ms-latency, schema-typed output. The fact-checker
   literally cannot write — verification comes from a model family that can
   only decide, not generate. Compilers check form; decision models check
   fidelity; generative models create.
   - **Slot, not dependency**: `verifier = decision-model | heuristic | none`.
     Availability is an Oct 26 question; the loop gates work with a heuristic
     fallback.
   - **Never on the render path.** It answers keep-iterating / accept /
     escalate-to-Wonder only — a loop gate, advisory, not a pipeline stage.
   - Verifier scores are *not* conformance metrics; never place them next to
     fixture counts as if equivalent.

## Model tiering (the broker routes slice AND tier)

- **Wonder (thinking)** — judgment calls in one clean context: the verdict
  reasoning, claim selection, research extraction. Gets the full research
  pack once. Its context is never polluted with diagnostic churn.
- **Spark (fast/cheap)** — iteration and cleanup: repair patches, field-by-
  field voice rewrites. Many small slice calls; cheap enough to loop.
- **Verifier (decision model, ms)** — per-field quality gates (did this
  rewrite improve?), citation entailment checks, escalation decisions.
  Turns blind iteration into scored iteration — and produces the convergence
  metrics for the eval slide.
- Iteration noise lives entirely in the cheap tiers; the thinking model only
  ever sees research → judgment. Open-weights verifiers route through
  Baseten/Modal/Fireworks credits (bonus-prize surface).

## Context economy (the design layer that makes it cheap)

The pipeline works in cache by nature, so the server is a **context broker**,
not a message pump. Rules:

1. **Disseminate, don't stuff.** Each Spark call receives the smallest slice
   that can do the job:
   - voice pass → one data field + the style guide + field's role in the doc.
     Not the template, not sibling fields, not the boris graph.
   - repair pass → the diagnostic + the template region around it (±N lines)
     + the grammar rule for that construct. Not the whole template.
   - research pass → ranked boris snippets. Never the graph.
2. **Cache-stable prefixes.** System prompt, subset-grammar appendix, and
   template schema are identical across every call — designed to hit prompt
   caching where the API offers it, and cheap regardless.
3. **Iterate pieces, not payloads.** Voice is applied field-by-field; repair
   is patch-per-diagnostic (fix first error, re-render, repeat — errors
   cascade, so don't batch). Whole-document regeneration is forbidden.
4. **Artifacts by handle, not by value.** Tools return `doc_id`/`data_id`
   handles; the client fetches content via MCP resources on demand. Large
   artifacts never enter client context unless asked for.
5. **The model can't see the layout.** Templates are server-side state.
   Spark literally lacks the context to break formatting — the guardrail is
   also the cost optimization. This is the slide.

## Tool surface (MCP)

- `knap_templates` — list templates + per-template JSON shape descriptor.
  Slim catalog by default; shape fetched per-template on request.
- `knap_validate(template_id, data)` — dry render. Returns ordered
  diagnostics (kind, line, col, detail) or `ok`. Cheap: no Spark call.
- `knap_render(template_id, data, target)` — `markdown` (k4o) | `oliver`
  (k4o) | `html` (dogbed). Buffered bytes or nothing; returns `doc_id`.
- `knap_repair(template_id, data)` — server-side bounded loop over *shipped*
  templates only (template_id, never caller-supplied text): render → extract
  error region → Spark patch → re-render. Max 4 iterations; on non-convergence
  returns best-effort + remaining diagnostics. Client sees one call; server
  sees N small ones. Convergence stats included in response.
- `knap_publish_check(doc_id, site)` — stage a copy of a rendered doc into
  the frozen boris site (boris frontmatter is a closed key set, so the staged
  copy keeps `title` only) and validate it with `boris validate --report`
  JSON. Unresolved wiki-links are hard `EREFERENCEMISSING` errors (exit 1);
  no flag is needed. Embeds are checked as links — boris 0.8.2 can't embed a
  page. Returns graph diagnostics: unresolvable references caught
  *pre-publish*. This is the layer-3 surface and a demo beat.
- `knap_lint(template_text)` — k4o education-grade lint, passthrough.
- `knap_voice(template_id, data, tone)` — field-by-field voice rewrite via
  Spark. `tone`: `mild | spicy | feral`. Returns patched data JSON + per-field
  diff count. Same template renders all tones — layout untouched.
- `knap_format_check(doc_id)` — advisory structure linter, ~8 pinned rules,
  warnings only, never blocks: skipped heading levels, wall-of-text where
  table-shaped data exists, unresolved footnotes, empty callouts, raw-URL
  count, heading/length ratio, unclosed fences, list-per-paragraph ratio.
- `boris_ask(query)` → ranked snippets from the frozen artifact.
- `boris_check(claim)` → grounded yes/no + citation from the artifact.

## Engine contract

- Engines: **k4o** main — knap-faithful, byte-compatible with knap 0.6.0;
  emits markdown or oliver — plus **dogbed** (html; pinned to the #33 head,
  which bundles k4o main). Textile and gfm are dropped (k4o keeps that
  legacy surface in its v0.1.0 release). 2nap retired to eval-corpus origin
  only.
- Grammar target: **the demo-needed referential subset, hard-scoped.** k4o
  main already ships all of it (plus `{% set %}` and `??`); the list stays
  as the scope contract for the demo templates.
  - Required (demo templates): `footnote`, `fragment_link`, `wikilink`,
    `callout`, `embed`, `image`, `yaml`, `yaml_property` + `{% set %}`, `??`
  - Stretch (only if above lands early): `map`, `where`, `sort`, `join`,
    `unique`, `first`/`last`, `length`
  - Cut for the event: `calc`, `math`, `duration`, `date_modify`, `truncate*`,
    `number_format`, `round`, `safe_name`, case filters, `replace`,
    `escape_md`, `strip_md`, `highlight`, `strike`, `hard_break`, `comment`,
    `unescape`, `*_uri`, `nth`/`slice`/`sum`/`object`/`compact`/`reverse`,
    `template`, `parse_json`, `merge`, `split`
  - Excluded permanently (need browser DOM): `html_to_json`, `remove_html`,
    `remove_attr`, `remove_tags`, `replace_tags`, `strip_attr`, `strip_tags`.
    Ingestion is boris's job.
  - Oracle scaffolding exists: the 188-case portable corpus already exercises
    the referential filters (footnote ×2, wikilink ×5, callout ×2, embed ×3,
    image ×3, fragment_link ×2, yaml ×11, yaml_property ×6) plus k4o's
    `tools/differential` live-diff. Measured: k4o main passes 187/188
    (`knap-mcp/eval/conformance/`). Note: the corpus is ~98% happy-path
    (2 error, 3 warning cases) — cite the *seeded-breakage* corpus for
    repair-path claims, not the 188.
  - **Cut-line pre-commitment**: if the referential subset isn't passing its
    corpus cases by Oct 29 EOD, the apparatus drops from demo templates and
    the demo runs on shipped filters only.
- Buffered rendering; errors → stderr, empty stdout, exit 1 (already the
  engines' contract; the server relies on it, never reimplements it).

## Repair state machine

```
draft → render → [ok] → done
               → [diag] → extract region(diag.line±N) → spark patch
                        → render → iter<4 ? loop : best-effort+diags
```

Each iteration's Spark call carries: stable prefix + diag + region + patch
grammar. Response is a *replacement region*, applied surgically — the model
never rewrites the whole template.

## Eval plan

- **Conformance**: 2nap's 41 output triples + 16 error cases; upstream
  `compat/fixtures/render.json` (188 cases) as the stretch corpus.
- **Repair eval**: seeded-breakage corpus — mutate the conformance fixtures
  through each pinned error class. Metric: convergence rate × mean iters.
  This produces the demo-slide numbers.
- **Voice eval**: same data × 3 tones → byte-identical layout assertions
  (structure hashes equal, strings differ). Proves the invariant.

## Demo script (~2 min, all-OSS pipeline)

vhs tapes → ffmpeg → Kdenlive → mp4. Muse Image title cards.

1. (5s) Cold open: AI doc — clean but *generic*: no callouts, no footnotes,
   no deep links, voice ironed flat. (Not a strawman "broken table" — the
   contrast is richness, not brokenness.)
2. (20s) Ask for a verdict from real data (frozen boris artifact). Templates
   are fixed; the model drafts *data only*.
3. (25s) Seeded template failure → pinned diagnostic → real repair loop →
   clean. Show diagnostic, patch, re-render visibly.
4. (30s) The doc: callouts, real table, footnotes, Muse Image art — sass intact.
5. (15s) The boris catch: a hallucinated wikilink fails `knap_publish_check`
   — references caught pre-publish, made visible.
6. (20s) Same template × mild vs feral — byte-identical layout (structure-
   hash equality on screen), different voice. The falsifiable proof.
7. (15s) One source → verdict.md + apparatus.html + verdict.oliver. Zero JavaScript.
8. (10s) Numbers card — *measured only*: fixtures passed (and k4o X/188 →
   Y/188 delta), repair convergence, server LOC, calls × mean slice size.
   No token-cost numbers unless real metering exists.

## Scope

In: tools above, context broker, the referential-filter worklist (scheduled
in GAMEPLAN), seeded evals, 3-5 templates, canned boris artifact, demo video.
Out: text/number-tier filters, UI, Obsidian anything, TypeScript anything,
live boris indexing, whole-doc Spark regeneration, model-drafted templates.

## Risks (ranked)

1. Meta Model API shape/metering → `llama-baseten` backend behind the same
   interface; decided Oct 26.
2. Spark voice quality → few-shot presets; architecture survives a weak model.
3. MCP client flakiness → dual-mode binary + vhs.
4. Boris integration → canned artifact is the floor, frozen Oct 24.
