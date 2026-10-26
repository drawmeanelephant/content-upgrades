# Cuntiness Eval — the formatting-density benchmark

Notes from the Oct 25 probe, for when the model list lands (Oct 26 kickoff).

## The thesis

LLM output regresses to boring: wall-paragraph, header, wall-paragraph, maybe
one table, no apparatus. "Cuntiness" = **formatting/emphasis density** — how
much structure and typographic apparatus a document carries per unit of prose.
It's the axis where models are laziest and nobody benchmarks.

Scope: **general-purpose markdown cuntiness, not a k4o feature.** Three
separable pieces — a renderer-agnostic density scorer on the markdown AST
(knap_format_check generalized), the apparatus vocabulary (the referential
knap subset: footnote/callout/wikilink/embed/fragment_link/image/yaml — that
list IS the cuntiness feature set), and the ratchet loop. k4o/dogbed and
WordCraft/DesignCraft are ceilings/proof targets, not the product. Pitch
corollary: "everyone else fixes AI markdown by making it smaller; we measure
how thin it is and add apparatus until it isn't."

Three claims to test:

1. Density is **measurable without a model** — deterministic, native, sub-second.
2. Density is **improvable by a bounded feedback loop** — the ratchet.
3. Density is **wildly variant across models** — a ranking axis worth a slide.

## The sensor — verified working Oct 25

WordCraft and DesignCraft are drivable over their control channels today; no
`wordcraft-cli`/`designcraft-cli` needed (only `vectorcraft-cli` 0.14 is
installed, and it predates WordCraft's key auth).

Launch (a window must stay open or the app quits):

```sh
DESIGNCRAFT_CONTROL_PORT=7983 /Applications/DesignCraft.app/Contents/MacOS/DesignCraft --sample
WORDCRAFT_CONTROL_PORT=7984 /Applications/WordCraft.app/Contents/MacOS/WordCraft --sample
```

Wire protocol — newline-delimited JSON over TCP:

```json
{"id":1,"method":"engine.commands","params":{}}                 // full catalogue
{"id":1,"method":"engine.execute","params":{"command":"...","params":{}}}
{"id":1,"method":"document.inspect","params":{}}               // block-level doc structure
{"id":1,"method":"ui.render","params":{"data":true}}           // visual proof
```

- WordCraft additionally wants `"key": "<contents of
  ~/Library/Application Support/WordCraft/control-key.local-PORT>"`.
- DesignCraft takes no key.
- `vectorcraft-cli mcp --connect 127.0.0.1:7983` also bridges DesignCraft as a
  32-tool MCP server (catalogue comes from the app); fails on WordCraft's auth.

Command surface: **DesignCraft 709** commands (InDesign-class — data merge
`data.*` incl. qr/image/hyperlink placeholders, XML tags + DTD validation,
`footnote.*`/`endnote.*`, anchored `note.*`, `book.*` multi-doc + one-PDF
export, object `library.*`, threaded `story.*`, GREP styles, drop caps, rules
above/below, full OpenType, PDF/EPUB/IDML export). **WordCraft 646**
(Word-class — `styles.*`, `outline.*`, `references.*`: real citations +
bibliography + `citationStyle` APA/Chicago + TOC + index + captions +
table-of-authorities + foot/endnotes; `design.*` themes/style-sets/watermark/
page-borders; `review.*`; 48 `table.*` commands; equations; SmartArt).

**Baseline measured live** on the WordCraft sample doc: 22 blocks, 8 paragraph
styles, 8 formatted runs, **7% styled-char coverage**. That is the boring
floor, quantified.

## The density score (never a model call)

Composite of signals `document.inspect` already returns:

- styled-char coverage % (runs carrying props / total chars)
- distinct paragraph + character styles in use
- block-type variety (paragraph vs table vs quote vs caption vs list)
- apparatus counts: footnotes, endnotes, citations, captions, cross-refs,
  TOC present/absent
- heading-per-N-words; table-shaped data actually *in* tables
- knap_format_check's pinned rules fold in as negative signals (skipped
  levels, wall-of-text, dangling refs, empty callouts, raw-URL count)

One number in → the loop has a gradient to climb.

## The ratchet loop

```
draft → inspect → density score
      → pick the single apparatus addition that most raises the score
      → engine.execute → re-inspect + ui.render proof
      → repeat until plateau or iteration budget
```

- Score-monotonic: a step that lowers density reverts.
- Bounded, like knap_repair (max ~4–8 iterations).
- Converges when no single command raises the score — "maximal", not infinite.
- Cheap-tiers-do-the-loop per SPEC: Spark-class iterates, Wonder-class judges.

## Model eval matrix — once the list lands

Same harness, vary the model. Two distinct eval modes, don't conflate:

1. **Values-only** (the knap voice contract): model writes `data.json` for a
   fixed template. Tests whether a model *uses* the apparatus slots offered —
   does it fill the footnotes, or leave them empty?
2. **Direct-drive** (agentic): model gets the `engine.commands` catalogue +
   `document.inspect` + `engine.execute` on a deliberately flat source doc.
   Tests whether it reaches for apparatus unprompted.

Per cell: density score achieved · iterations to plateau · contract
violations (did it touch layout when told not to) · judgement (dense ≠ noisy —
does the apparatus fit the content or is it confetti).

Slide numbers this produces: "model X hits 12% styled coverage unaided, 47%
after 3 ratchet iterations" / "model Y fills 0/6 footnote slots" etc.

## What counts as cunty vs lazy (seed the rubric)

- pull quotes, kickers, decks, margin notes — used or absent
- footnotes/endnotes with real content vs none
- tabular data in tables vs prose-described
- emphasis variety beyond bold: small caps, color, rules, styled runs,
  drop caps
- headings that are descriptive, levelled, and actually used
- citations/links as apparatus vs raw URLs
- signature moves: folios, page borders, watermarks, themed palettes,
  GREP-style auto-emphasis
- WC one-command tone shifts: `design.styleSet`, `design.themeFonts`,
  `design.pageBorders`, `design.watermark`

## Fit to the pitch

"AI can't do layout. So we don't let it." — the eval is the *proof of the
wound*: even where models may touch layout they under-format. The product
answer is budget-in-template (DC styles + data merge = knap data.json →
designed PDF/EPUB, not markdown→HTML) plus the density ratchet.

Per SPEC: keep eval numbers on their own axis — density scores are not
fixture conformance and never sit next to the 188-case corpus counts.

## Model list (landed Oct 26)

- **Iteration / voice:** `muse-spark-1.3` — 1M ctx, 131k out, multimodal in,
  OpenAI/Anthropic-compatible, encrypted reasoning carry-over for tool loops.
- **Judgment:** `muse-wonder-1.0` — reasoning effort minimal→max; Standard
  mode only via API (Full is Muse-Code-locked).
- **Cheap iteration / verifier candidates:** `muse-spark-open-1026` on Baseten
  (2M TPM if credits land), `muse-glimmer` self-host (post-trainable — a
  trained density judge is a stretch goal, not a dependency).
- **Eval grid:** every generative model the account exposes — wonder vs spark
  is already an interesting density axis (does capability spend on apparatus?).

Open items: harness location (standalone script driving the control channel
first; fold scorer into `knap_format_check` later); DesignCraft wants
`DESIGNCRAFT_CONTROL_PORT` env, not `--control`.
