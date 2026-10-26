# Next-phase plan: density scorer, ratchet loop, sequencing

**Baseline.** This plan is based on:
- knap-mcp at `81a6596` (branch `feat/apparatus-templates`, PR #4)
- k4o at `feat/parser-blocks` `f97c5db` (the #70/#71 work)
- dogbed at `0c94175`
- boris 0.8.2
- Oliver at `62503d1`

Today is kickoff day (Oct 26). Feature freeze is Oct 30.

## 0. Verified findings that change the plan

| # | Finding | Evidence | Consequence |
|---|---|---|---|
| F1 | **k4o filter arguments can't see loop variables.** `filters.apply` receives `self.root`, and `argText` resolves bare arguments with `root.get(name)`. Loop variables and `{% set %}` bindings (kept in `self.vars`) are invisible to them. | `engine.zig:180`, `filters.zig:821-850` | Inside `{% for %}` you can't write `{{ s.name \| link: s.url }}`, `fragment_link: s.url`, `wikilink: s.label` or `image: s.alt`. This is why the current templates print `{{ s.url }}` bare and trip `raw-url-count`. Fixing it is the **largest single density unlock**. |
| F2 | The `callout` type and title are tuple **literals** (quoted strings and booleans only). Data supplies only the body. | `filters.zig:237-296` | Good for the invariant: the template enumerates the allowed callout kinds with `{% if c.kind == "warning" %}` chains (`CmpOp.eq` exists). |
| F3 | The `footnote` filter emits **definitions only** (`[^1]: …`, or `[^slug]: …` for objects). `verdict.knap` has no reference sites. | `filters.zig:397-431` | Every footnote in the sample render trips `unused-footnote`, and an honest scorer gives it zero footnote credit. Templates need reference slots. |
| F4 | In `markdown` format, k4o's `table` emits an **HTML `<table>`**. Pipe tables only appear in `gfm`. | `filters.zig:1113-1155` | The scorer must recognize both forms. The ratchet scores the `gfm` render. |
| F5 | **dogbed renders knap → k4o *Textile* → Oliver textile → HTML.** The referential filters pass markdown syntax through Textile unchanged. Oliver's *markdown* parser has opt-in footnotes, wikilinks and callouts; its textile parser only has `fnN.` footnotes. dogbed pins k4o `5bafceb`, which is 55 commits behind `origin/main`. | `dogbed/src/main.zig:9,258-279`, `oliver/src/markdown.zig:114-148` | **Bumping the dependency alone gives literal `[[…]]`, `> [!note]` and `[^1]:` text in the HTML.** `apparatus.html` needs a markdown → Oliver path in dogbed. |
| F6 | boris `check` has `--fail-on-unreferenced` (orphan pages). There is **no `--fail-on-unlinked`**. Hallucinated wikilinks are caught by `boris validate` and `build`: `error: EREFERENCEMISSING: index.md:8:9: wiki-link heading target … not found`. That took **0.01 s** on a contract fixture. `check --format json` writes to stderr unless you pass `--report PATH`. | `boris --help`; live run | `knap_publish_check` should run `validate` for references and `check` for graph health. The SPEC wording needs a fix. |
| F7 | boris wikilink targets are **entity IDs** (derived from file paths), not page titles. `[[id#heading-id]]` is checked against the target page's rendered heading IDs. | `includes-and-wiki-links.md:53-66` | `{{ s.name \| wikilink }}` with "AcmeDB docs — backups" fails on every link. Sources need an `id` field. |
| F8 | boris frontmatter is **closed**. Only `id`, `title`, `parent`, `status`, `tags`, `relations`, `published_at`, `summary` and `servings` are allowed. Unknown keys raise `EFRONTMATTER`, and `tags` must be a bracket list. k4o's `yaml` filter emits block lists. | `frontmatter.md:125,158-166` | The `verdict.sample.json` frontmatter (`year`, `genre`, `verdict`) fails boris. Templates need boris-safe frontmatter. |
| F9 | boris 0.8.2 has no `search-index` or `source-rag` subcommand. RAG output comes from `boris --rag`, `--context` or `--llms`, and boris's AGENTS.md calls source-RAG tools standalone labs. | `boris --help` | `boris_ask` reads a pre-built pack. The ranking is ours to write. |
| F10 | knap-mcp housekeeping: `writeOutcome` always stores repaired docs as `.md`, even for html or textile targets. `store.read` matches the `doc_id.` prefix, so a sidecar named `doc-X.meta.json` would collide with `doc-X.md`. `chatCompletion` puts the bearer token and the payload on curl's argv, which makes the token visible in `ps` and caps the payload at ARG_MAX. | `tools.zig:250`, `store.zig:48-49`, `backend.zig:160-167` | Fix these before adding sidecars or large prompts. |
| F11 | k4o and dogbed are **not on PATH** here (`which` found only `boris`). The Makefile `eval` target doesn't set `KNAP_K4O_PATH`. | `which` | Every demo and eval run needs the environment variables. Add them to the Makefile. |
| F12 | `README.md` says "cheap models score the result for formatting density". `cuntiness-eval.md` says the score is "never a model call". | docs | They contradict. I assume the scorer is deterministic (§1) and the README should be fixed. |

## 1. Density scorer (`src/density.zig`)

### 1.1 Contract

- Pure text in, a `Report` out. No model call, no allocation beyond the arena, and the same input always gives the same score (rounded to 0.1).
- It scores **markdown or gfm docs only**. Textile uses different heading and emphasis syntax, and the referential filters emit markdown even in Textile. HTML is scored through the markdown sibling render, because layout is identical across targets by construction. A textile or html `doc_id` gets an error saying "render target=gfm".
- The score is 0–100, versioned as `density/1`. Every number on a slide cites the scorer version.
- It reuses formatcheck's line model. Make `headingLevel`, `isListItem`, `countWords`, `scanNotes` and `countBareUrls` `pub` in `formatcheck.zig` so the two modules never disagree about what a line is. formatcheck warnings become penalties, so **a warning-free doc never loses points**.

### 1.2 Signals and detection

All detection skips leading frontmatter (except the frontmatter signal itself) and fenced code (except the code signal itself).

| Signal | Detection on gfm/markdown text | Produced by |
|---|---|---|
| `footnotes` | IDs present as both a reference `[^id]` (not followed by `:`) and a definition `[^id]:`. Only resolved pairs count. | `footnote` plus a template reference slot |
| `fragment_links` | `](…#:~:text=…)` | `fragment_link` |
| `callouts` | A `> [!type]` line followed by at least one non-empty `> ` body line | `callout` |
| `wikilinks` | `[[` not preceded by `!` | `wikilink` |
| `embeds` | `![[` | `embed` |
| `images` | `![…](…)` that isn't `![[` | `image` |
| `frontmatter` | Top-level `key:` lines between leading `---` fences | `yaml` / `yaml_property` |
| `headings` | ATX headings: their count per unit (defined in §1.3) and the set of levels used | `h1`–`h6` |
| `tables` | A gfm `\|…\|` line followed by a delimiter row, or a markdown `<table>`. Counts tables. | `table` |
| `quotes` | Runs of contiguous `> ` lines that aren't callouts | `blockquote` |
| `lists` | List-item lines | `list` / `numbered` |
| `code` | Fenced blocks plus inline code spans | `code` / `codeblock` |
| `styled_coverage` | Characters inside `**…**`, `*…*`/`_…_`, `` `…` ``, `[text](…)`, `[[…]]` labels, `==…==` and `~~…~~`, divided by visible characters in prose lines (paragraphs, list items, quote and callout bodies, table cells) after stripping markup tokens. This is the markdown version of WordCraft's "styled-char coverage". | `bold`, `italic`, `code`, `link` |
| `emphasis_variety` | Distinct inline kinds used, from {bold, italic, code, link, wikilink, fragment_link, strike, highlight} | — |
| `links` | `[text](http…)`, autolinks `<http…>` and fragment links | `link`, template `<{{ url }}>` |
| `block_variety` | Distinct block kinds used, from {paragraph, heading, list, table, quote, callout, code, footnote_def, image/embed, hr, frontmatter} | — |

### 1.3 Formula

$W$ is the number of prose words, excluding markup tokens, frontmatter, code and HTML tags. Each signal $i$ has a count $c_i$, a weight $w_i$ and a target rate $k_i$:

$$u = \frac{\max(W, 150)}{250}, \qquad r_i = \frac{c_i}{u}, \qquad s_i = 1 - e^{-r_i / k_i}$$

$$D = \operatorname{clamp}\Big(\sum_i w_i\, s_i \;-\; \sum_j p_j,\; 0,\; 100\Big), \qquad \textstyle\sum_i w_i = 100$$

- **Unit = 250 words**, roughly a screen of prose. The 150-word floor stops one callout in a 40-word doc from saturating its signal.
- **Saturation.** $s_i$ reaches 0.63 at the target rate, 0.86 at twice the target and 0.95 at three times. Spamming one signal earns at most $w_i$ points, so the score rewards variety **without a separate variety multiplier**. That is the anti-confetti property.
- **Presence-type signals** use a capped ratio instead:
  - frontmatter: $\min(1, \text{fields}/5)$
  - block variety: $\min(1, \text{kinds}/6)$
  - emphasis variety: $\min(1, \text{kinds}/4)$
- **Headings** score $0.5\cdot\text{sat}(r, k{=}1.5) + 0.5\cdot\min(1, \text{distinct levels}/3)$.
- **Styled coverage is a band, not a monotone signal.** With $\text{cov}$ the styled fraction:
  - $s = \min(1, \text{cov}/0.15)$ while $\text{cov} \le 0.25$
  - $s = \max(0,\ 1 - 2(\text{cov} - 0.25))$ above 0.25

  Full credit runs from 15% to 25% coverage, and the credit is gone by 50%. For reference, WordCraft's measured floor is 7%.

### 1.4 Weights (pinned; changing them bumps `density/1`)

| Group | Signal | $w$ | $k$ (per 250 words) | Rationale |
|---|---|---|---|---|
| **Apparatus (45)** | footnotes (resolved) | 10 | 1.0 | The core of the pitch, and the hardest thing for a model to fake honestly |
| | fragment_links | 8 | 0.5 | Deep-link citations are the apparatus nobody renders |
| | callouts | 8 | 0.5 | The most visible "rich vs flat" signal for the cold open |
| | wikilinks | 7 | 1.5 | Cheap to emit, so a higher target rate |
| | embeds | 4 | 0.3 | Rare by nature |
| | images | 3 | 0.3 | Rare by nature; Muse Image art |
| | frontmatter | 5 | fields/5 | Metadata as apparatus |
| **Structure (30)** | headings (rate + levels) | 8 | 1.5 | Levelled and actually used |
| | tables | 8 | 0.5 | "Tabular data in tables" |
| | block_variety | 6 | kinds/6 | Block-type variety, from cuntiness-eval |
| | quotes / pull quotes | 4 | 0.5 | Kickers and pull quotes |
| | lists | 2 | 3.0 | Low weight: lists are what flat docs already overuse |
| | code | 2 | 0.5 | Low weight: verdict blogs rarely need it |
| **Inline (25)** | styled_coverage (band) | 12 | band | The styled-run coverage metric |
| | emphasis_variety | 6 | kinds/4 | "Emphasis variety beyond bold" |
| | links | 7 | 2.0 | Links as apparatus. Bare URLs are handled by penalties, not here, to avoid double counting. |

### 1.5 Penalties (points subtracted after weighting; total capped at 40)

| Rule | Source | Per hit | Cap |
|---|---|---|---|
| `unclosed-fence` | formatcheck | 10 | 10 |
| `unresolved-footnote` | formatcheck | 3 | 9 |
| `empty-callout` | formatcheck | 3 | 9 |
| `wall-of-text` | formatcheck | 4 | 8 |
| `skipped-heading` | formatcheck | 2 | 6 |
| bare URLs | `countBareUrls` (count directly, don't parse warning text) | 1 per URL | 5 |
| `unused-footnote` | formatcheck | 1 | 4 |
| `heading-ratio`, `list-heavy` | formatcheck | 3 | 3 each |
| `callout-confetti` (new) | more callouts than prose paragraphs | 5 | 5 |
| `heading-confetti` (new) | 4 or more headings with a mean section under 25 words | 5 | 5 |

These new noise rules plus the coverage band are the deterministic part of "dense ≠ noisy". The fitness judgment from cuntiness-eval stays an optional advisory column that a model may fill. It never feeds the score.

### 1.6 Sanity check by hand (the corpus replaces this, see §1.8)

- **Flat** (600 words: wall paragraph, two h2s, wall paragraph, a bit of bold): headings ≈ 3.0, block variety ≈ 2.0, coverage ≈ 0.8, emphasis variety ≈ 1.5. **About 7–8 points.**
- **Rich** (a fully filled verdict v2 page of about 500 words, with 4 footnote pairs, 3 fragment links, 2 callouts, 4 wikilinks, 1 embed, 1 image, 4 frontmatter fields, 6 headings across h1–h3, 1 table, 1 pull quote, about 12% coverage and 6 links): apparatus ≈ 38, structure ≈ 22, inline ≈ 21. **About 81 points.**
- **Confetti** (10 callouts in 200 words, 40% bold): callouts are capped at 8 points, the coverage band drops to 0.7, and `callout-confetti` subtracts 5. It lands well below the rich doc.

### 1.7 Code layout, mirroring formatcheck

```zig
// src/density.zig
pub const version = "density/1";
pub const Signal = enum { footnotes, fragment_links, callouts, wikilinks, embeds, images, frontmatter,
    headings, tables, block_variety, quotes, lists, code, styled_coverage, emphasis_variety, links };
const Mode = enum { rate, ratio, band, headings };
const Spec = struct { signal: Signal, weight: f64, k: f64, mode: Mode };
// Pinned: part of the scorer contract. Changing a row bumps `version`.
const specs = [_]Spec{ .{ .signal = .footnotes, .weight = 10, .k = 1.0, .mode = .rate }, ... };

pub const Counts = struct { words: usize, footnote_pairs: usize, ..., styled_chars: usize,
    prose_chars: usize, heading_levels: u8, block_kinds: u16, inline_kinds: u8, bare_urls: usize };
pub const Component = struct { signal: Signal, count: f64, rate: f64, sub: f64, weight: f64, points: f64 };
pub const Penalty = struct { rule: []const u8, hits: usize, points: f64 };
pub const Report = struct { score: f64, words: usize, groups: [3]f64,
    components: []Component, penalties: []Penalty, kinds_used: u8 };

pub fn measure(alloc: std.mem.Allocator, doc: []const u8) !Counts;
pub fn score(alloc: std.mem.Allocator, doc: []const u8) !Report;   // calls formatcheck.check
pub fn structureHash(doc: []const u8) u64;  // block/inline kind sequence, text ignored (§1.9)
```

**Tool `knap_density`.** Input: `{"doc_id": "..."}`, or `{"template_id": "...", "data": {...}}`. The second form renders gfm internally and stores the doc.

```json
{"ok":true,"scorer":"density/1","doc_id":"doc-…","score":62.4,"words":512,
 "groups":{"apparatus":31.2,"structure":18.0,"inline":13.2},
 "components":[{"signal":"footnotes","count":4,"rate":1.95,"sub":0.86,"weight":10,"points":8.6}],
 "penalties":[{"rule":"unused-footnote","hits":2,"points":-2}],
 "kinds_used":9,"structure_hash":"9f3c…"}
```

**CLI.** `knap-mcp density <doc_id>` (mirrors `cmdFormatCheck`) and `knap-mcp density-eval [--corpus eval/density/corpus.json]`. Add the tool to `tools.all`, the usage text and the README. Unit tests go next to the code, in the same style as formatcheck's eight tests: one per signal, one per penalty, a saturation test, the coverage band, and a test that a warning-free doc has zero penalties.

### 1.8 Seed corpus for calibration (`knap-mcp/eval/density/`)

`corpus.json` lists each doc: `{"id","class","path","source","notes"}`.

| Class | n | Contents |
|---|---|---|
| `flat` | 8–12 | Raw Spark and Wonder answers to four fixed prompts with no template ("write a verdict on AcmeDB", "summarize these sources", …). These double as the model-matrix baseline. Until `MODEL_API_KEY` exists, use 4 hand-written emulations of the wall-paragraph pattern. |
| `generic` | 3–4 | Templates rendered with **only the required fields** filled. This is the "clean but generic" cold-open artifact. |
| `rich` | 8–12 | verdict v2 and apparatus v2 fully filled; 3–4 hand-authored Obsidian-style notes with callouts, footnotes, wikilinks and embeds; one boris contract page (a structured midpoint with dense tables and little apparatus); k4o `src/init/knap-tour.md`. |
| `confetti` | 4–6 | Adversarial spam: callout floods, bold floods, a heading every two lines. |
| `ladder` | 1 base × about 8 steps | `verdict.min.json` plus cumulative data patches listed in `ladder.json`, one optional slot per step. The harness renders each step. This uses the same mechanism as the ratchet probes, so it tests both. |

`expect.json` turns calibration into a gate, so `density-eval` exits 1 when an expectation fails:

```json
{"flat_median_max":15,"generic_range":[15,35],"rich_median_min":65,
 "confetti_max_lt_rich_median":true,"ladder_step_min_gain":1.0}
```

Calibration procedure:
1. Tune `k` first, since it controls saturation, and leave the weights alone.
2. Freeze `density/1` before **any** model-matrix run.
3. If you retune later, bump to `density/2` and rerun everything.

Corpus docs must be ours or MIT-licensed.

### 1.9 Bonus: the structure hash feeds the voice proof

SPEC demo beat 6 needs "structure hashes equal". `structureHash` is the scorer's block and inline kind sequence with text dropped, hashed with `std.hash.Wyhash`. The voice eval reuses it, so there's no second parser.

## 2. Ratchet loop (`src/ratchet.zig`)

### 2.1 How it differs from repair

| | `knap_repair` | `knap_ratchet` |
|---|---|---|
| Input | A broken template (a seeded working copy) | A **valid** render (template plus data) |
| What it changes | A template region, in the working copy | **Data JSON only**: it fills an empty optional slot or appends one item to an array slot |
| What the model returns | Replacement region text | **One JSON value for one named slot**, or `null` |
| Who picks the next step | The engine (first diagnostic) | **The server, through stub probes.** The model never picks which apparatus to add, because that would be the model *choosing* layout, which SPEC's precise pitch forbids. |
| How a step is judged | Engine exit code | Density gain ≥ ε, a clean render, no new formatcheck warnings, and the verifier passes |
| Termination | ok, no patch, or 4 iterations | `ceiling`, `plateau`, `stalled`, `max_iterations` or `budget` |
| On failure | Best effort plus diagnostics | Always returns the best data so far (scores only go up) |

Each tool has one job: **repair fixes templates, ratchet adds data, voice rewrites existing values.** The ratchet never changes a non-empty value.

### 2.2 Shape annotations (an extension to `templates/shapes/*.json`)

```json
"callouts": {"type":"array<object>","optional":true,"apparatus":"callout","max_items":3,
  "role":"boxed aside flagging a risk or a tip","words":30,
  "fields":{"kind":{"type":"string","enum":["warning","tip","note"]},
            "body":{"type":"string","voice":true,"max_words":40}}},
"pull_quote": {"type":"string","optional":true,"apparatus":"quote","evidence":true,"max_words":30,
  "role":"verbatim line from a source, rendered as a blockquote"},
"claims": {"type":"array<object>","optional":true,"apparatus":"footnote","max_items":6,
  "fields":{"text":{"type":"string","voice":true},"note":{"type":"string","ref":"footnotes"}}},
"footnotes": {"type":"object<string>","optional":true,"apparatus":"footnote","evidence":true}
```

New keys:
- `apparatus` is one of {footnote, callout, wikilink, embed, image, fragment_link, table, quote, frontmatter, list}.
- `max_items` bounds how far an array can grow.
- `words` sizes the probe stub.
- `evidence: true` sends the slot through the verifier gate.
- `ref` declares cross-field ID integrity (for example, a claim's `note` must be a key in `footnotes`).

### 2.3 Template v2 requirements (the ratchet has nothing to climb without these)

1. **Footnote references.** Change `footnotes` to an object keyed by note ID, and add `{% for c in claims %}- {{ c.text }}[^{{ c.note | kebab }}]{% endfor %}`. formatcheck's `unresolved-footnote` then catches the model citing a note that doesn't exist.
2. **Callouts as an if-chain** over the enumerated kinds: `{{ c.body | callout:("warning", "Heads up") }}` and so on. The title and type stay template-authored (F2).
3. **Source URLs** become autolinks, `<{{ s.url }}>`, today. Once arguments can see loop variables (F1), switch to `{{ s.name | link: s.url }}`.
4. **Wikilinks** use `{{ s.id | wikilink }}`, with `id` set to the boris entity ID. boris uses the page title as the default label, so no alias argument is needed (F7).
5. **Boris-safe frontmatter**, built from `yaml_property` per key: `title`, `summary`, `status`, and `tags` as a flow list (F8).
6. **New top-level slots**: `pull_quote | blockquote`, `hero_url | image: hero_alt` (top-level arguments work today), and 1–2 top-level `fragment_link` slots until F1 lands.
7. **Two sample data files**: `verdict.min.json` (required fields only) and `verdict.full.json` (every slot filled). The full render must produce **zero** formatcheck warnings.

### 2.4 Algorithm

```text
ratchet(template_id, data0, backend, opts):
  shape  = loadShape(template_id); slots = apparatusSlots(shape)        # optional + apparatus-annotated
  doc0   = render(gfm, tpl, data0)
  if doc0 has diagnostics: return {ok:false, diagnostics, hint:"data error; ratchet needs a valid render"}
  best   = {data: data0, doc: doc0, score: density(doc0), warns: formatcheck(doc0)}
  ceiling = density(render(fillAllStubs(data0, slots)))                 # the template's own ceiling
  calls = 0
  for iter in 0 ..< opts.max_iterations:
    if ceiling - best.score < eps:                 stop = ceiling; break
    cands = []
    for slot in slots where canGrow(best.data, slot):                   # empty scalar, or array < max_items
      probe = withStub(best.data, slot)                                 # shape-typed placeholder, never shipped
      r = render(probe); if r has diagnostics: continue
      cands.push({slot, gain: density(r) - best.score})
    sort cands by gain desc, then shape order (deterministic tie-break)
    if cands empty or cands[0].gain < eps:         stop = plateau; break
    accepted = false
    for c in cands[0 ..< top_k]:
      if calls == opts.max_calls:                  stop = budget; break outer
      value = backend.enrichValue(kind, buildSlice(c.slot, shape, best.data, evidence, tone)); calls++
      reject unless parseJson(value) and schemaOk(value, c.slot) and isInert(value)
                    and (not c.slot.evidence or verifier.ok(value, evidence))
      cand = setSlot(best.data, c.slot, value)                          # server-side write, never model-side
      r = render(cand); reject if diagnostics
      s = density(r); w = formatcheck(r)
      if s >= best.score + eps and w ⊆ best.warns:
        best = {cand, r, s, w}; accepted = true; break
      else reject(no_gain | new_warnings)
    if not accepted:                               stop = stalled; break
  stop = stop or max_iterations
  return {best, ceiling, steps, stop, converged: stop in {ceiling, plateau}}
```

- **Termination.** Every accepted step adds at least ε to a score capped at 100, and `max_iterations` caps the loop on top of that.
- **Probe gain is only an estimate**, because stub word counts differ from the real value's. That is why the accept check re-scores the real render.
- **Probe cost** is about (number of slots) × (iterations) k4o renders, roughly 8 × 6 = 48 subprocess runs. Measure it before claiming anything about latency.

### 2.5 Backend change

First refactor `remotePatch`'s transport into a shared primitive. repair, enrich, voice and the future ACP backend all slot in here.

```zig
pub fn complete(ctx: *Ctx, kind: Kind, system: []const u8, user: []const u8) Error![]const u8;
pub fn enrichValue(ctx: *Ctx, kind: Kind, slice: []const u8) Error!?[]const u8; // .mock → canned table
```

While refactoring, pass the payload and auth header through `--data @<scratch file>` and `-H @<file>` (F10), and keep `usage` from the reply so the numbers card can report measured tokens.

**`enrich_prefix`** is the system prompt. It is cache-stable, identical on every call:

```text
You fill ONE empty field in a JSON data document for a fixed, human-authored template.
You never see the template and you never write markup: no markdown, no HTML, no brackets,
no headings, no pipes. Return ONLY a JSON value matching the schema. No prose, no code fences.
Use only facts in EVIDENCE; copy quotes verbatim. If EVIDENCE cannot support the field, return null.
```

**The slice** is the user message, kept under 4 KiB:

```text
FIELD: callouts[+]   (append one item)
SCHEMA: {"type":"object","fields":{"kind":{"enum":["warning","tip","note"]},"body":{"type":"string","max_words":40}}}
ROLE: boxed aside flagging a risk or a tip for the reader
TONE: spicy
HEADLINE: {"title":"Verdict: AcmeDB","verdict":"give a shit","take":"the boring database that actually ships"}
SIBLINGS: [ ...existing items in this array, to avoid duplicates... ]
EVIDENCE: [{"id":"s1","quote":"Point-in-time snapshots are coming soon."}, ...]
```

**The model's only controls** are the value for the one slot the server picked, choosing among template-enumerated `enum` options, and declining with `null`. It has no say over which slot is filled, how many items there are, their order, or any markup.

### 2.6 Guards

- **Schema check**: type, `enum`, `max_words`, an `http`/`https` scheme for URLs, and `ref` integrity (IDs must already exist in the referenced field).
- **`isInert` contract check**: reject string values that contain `[[`, `![[`, `[^`, `](`, `> [!`, a heading `#` at the start of a line, a pipe at the start of a line, triple backticks, `<tag`, `{{` or `{%`. Each rejection counts as a **contract violation**, which is the "did it touch layout" column in the cuntiness-eval matrix. Without this check, a model could raise its own score by writing markdown inside values.
- **Verifier gate (layer 4, advisory)**: for `evidence` slots, the heuristic verifier requires a whitespace-normalized **verbatim substring** of an evidence item. For `fragment_link` text this is also a correctness check, since `#:~:text=` only resolves if that text is on the target page.

### 2.7 Constants (pinned in `ratchet.zig`)

| Constant | Value | Why |
|---|---|---|
| `default_max_iterations` | 6 | Inside cuntiness-eval's 4–8 range; each iteration adds one item |
| `epsilon` | 1.0 point | Below this is noise, roughly one extra list item |
| `top_k` | 2 | One retry per iteration if the best slot is rejected |
| `max_backend_calls` | 10 | A hard cost cap, below iterations × `top_k` |
| `max_slice_bytes` | 4096 | Follows SPEC's "disseminate, don't stuff" rule |

### 2.8 Tool, CLI and eval

`knap_ratchet` input:

```json
{"template_id":"verdict","data":{},"backend":"mock","max_iterations":6,"epsilon":1.0,"tone":"spicy","evidence":"data"}
```

`evidence` is `"data"` (the quotes in `data.sources[*]`) or `"boris"` (`boris_ask` snippets, once that tool exists).

Output:

```json
{"converged":true,"stop":"plateau","iterations":4,"calls":5,
 "score":{"scorer":"density/1","start":18.2,"final":63.5,"ceiling":78.0},
 "slot_fill":{"start":"2/9","final":"7/9"},
 "data_id":"doc-…","doc_id":"doc-…",
 "steps":[{"iteration":0,"slot":"callouts[+]","probe_gain":7.9,"gain":6.8,"accepted":true,"reason":"ok"},
          {"iteration":1,"slot":"pull_quote","probe_gain":4.1,"gain":0,"accepted":false,"reason":"verifier:not-verbatim"}]}
```

- **CLI**: `knap-mcp ratchet <id> -d data.json [--backend b] [--max-iters n]`.
- **Mock**: canned values keyed by slot path in `eval/ratchet-mock.json`, so the full loop can be demoed and tested with no API key.
- **Eval**: `knap-mcp ratchet-eval --corpus eval/ratchet.json --backend <b>`. Each row has start, final, ceiling, iterations, calls, accepted, and rejections broken down by schema / inert / render / verifier / no-gain, plus the stop reason. Running it once per backend gives the values-only model matrix. Keep these numbers **off** any row that shows fixture conformance (SPEC rule).

## 3. Sequencing

| When | Work | Why this slot | Depends on | Done when |
|---|---|---|---|---|
| **Oct 26** | Merge k4o #70/#71 and knap-mcp #4. Add `KNAP_K4O_PATH`/`KNAP_DOGBED_PATH` to the Makefile. **When the key lands**: `knap-mcp backends`, then `knap-mcp eval --backend spark`. | GAMEPLAN's day-1 must-do. Repair is the beat you don't control, and the code already exists. | Key | Convergence table saved |
| **Oct 27 AM** | `density.zig`, `knap_density`, CLI, unit tests | Pure native code, no dependencies, unblocks everything else | — | `zig build test` green |
| **Oct 27 PM** | Density corpus and `density-eval` gate. **Freeze `density/1`.** | Calibrate before any number exists | density | `expect.json` passes |
| **Oct 27, in parallel (other repos)** | **k4o**: filter arguments resolve through the scope chain (F1). **dogbed**: bump the k4o pin, plus a markdown → Oliver path with footnotes, wikilinks and callouts enabled (F5). | F1 is the biggest density unlock. F5 is required for `apparatus.html`. | Filters merged | dogbed renders a callout as a callout box |
| **Oct 28 AM** | Templates v2, shape annotations, `min`/`full` sample data | The ratchet needs slots | Filters (F1 preferred; the fallbacks in §2.3 work without it) | full ≥ 65 with zero warnings; min ≤ 35 |
| **Oct 28 PM** | `backend.complete` refactor, `enrichValue`, `ratchet.zig`, `knap_ratchet`, mock | The headline loop | density, v2 | The mock run climbs from min to ≥ 60 in ≤ 6 iterations |
| **Oct 29 AM** | `knap_publish_check` plus a frozen site with one page per source ID | Demo beat 5, and it's cheap (measured 0.01 s) | Site content | The hallucinated-wikilink seed produces `EREFERENCEMISSING` |
| **Oct 29 PM** | `verifier.zig` (heuristic) as the ratchet gate; `boris_ask`; `boris_check` built as ask plus verifier | Keeps the ratchet's additions grounded in evidence | publish site | The ratchet rejects a fabricated quote |
| **Oct 29 EOD** | **Cut-lines.** Filters (GAMEPLAN). dogbed markdown path: if it isn't working, demo beat 7 ships `verdict.md`, `apparatus.md` and textile, and html only for templates without apparatus. | | | |
| **Oct 30** | Real Spark/Wonder/Baseten ratchet eval and the model matrix. `knap_voice` reuses the slice builder; the structure-hash proof. **FREEZE.** | | Key | Matrix table saved |
| **Oct 31** | Buffer only | | | |
| **After freeze** | ACP backend | Per acp-backend.md. The `complete()` refactor makes it a single function. | — | — |

**Item details:**

- **`knap_publish_check(doc_id, site, path?)`** lives in new `src/boris.zig`:
  1. Copy `sites/<site>/content` to scratch. Never touch the frozen artifact.
  2. Write the doc to `content/<path>`.
  3. Run `boris validate --input <tmp>` and parse lines of the form `error: CODE: file:line:col: detail [remediation]`.
  4. Run `boris check --input <tmp> --format json --report <tmp>/check.json`.

  Environment: `KNAP_BORIS_PATH`, `KNAP_SITES_DIR`. Output:

  ```json
  {"ok":false,"validate":{"exit":1,"diagnostics":[{"code":"EREFERENCEMISSING","file":"verdicts/acmedb.md","line":12,"column":3,"detail":"…"}]},
   "check":{"unreferencedPages":1,"hotspots":0},"ms":14}
  ```

- **`boris_ask(query, site, k=5)`** reads a pack built ahead of time with `boris --rag` or `--context` (F9). Ranking is a small term-frequency scorer in Zig, around 150 lines. That is retrieval, not engine logic, so it doesn't break non-negotiable #1, but it is new code to budget for.
- **`boris_check(claim)`** is `boris_ask` followed by `verifier.checkCitation`, returning `{"grounded":bool,"citation":{"page_id","quote"},"verifier":"heuristic"}`. It therefore comes after the verifier.
- **Verifier slot** (`src/verifier.zig`): `Kind = enum { none, heuristic, decision }` and `checkCitation(ctx, kind, claim, quote) → {label: entails|neutral|contradicts|unknown, score}`. Build the heuristic first. A decision model is used only if a partner model turns up. Its scores are never presented next to conformance numbers.
- **Real Spark eval** is its own track, not part of the day schedule. Smoke checks to run:
  - `GET /v1/models` to confirm the IDs `muse-spark-1.3` and `muse-wonder-1.0`.
  - Whether reasoning models accept `temperature: 0`.
  - Whether `message.content` is ever an array, or whether reasoning arrives in separate fields (`chatCompletion` assumes a string today).
  - Record `usage` from replies.
- **ACP.** Do it only after the `complete()` refactor. ACP agents bring their own system prompts and tools, so JSON-only output is less reliable. The schema and inert guards matter more there. Never use ACP output for eval numbers.

## 4. Ambiguities and the assumption I made for each

1. **Is "density" a markdown measure or a WordCraft measure?** cuntiness-eval's signals come from WordCraft's `document.inspect` (styles and runs). *Assumption:* markdown equivalents (§1.2) inside knap-mcp. Driving WordCraft or DesignCraft directly is a separate eval mode, outside knap-mcp for the hackathon. Cite the 7% figure only as a baseline.
2. **Model-scored or deterministic?** (F12) *Assumption:* deterministic. A model may add only an advisory "fit" column.
3. **Which target gets scored?** *Assumption:* markdown or gfm only. The ratchet scores gfm.
4. **Does the ratchet edit data or drive the engine?** cuntiness-eval's loop calls `engine.execute`. *Assumption:* values-only inside knap-mcp.
5. **Who picks "the single addition that most raises the score"?** *Assumption:* the server, through probes (§2.1). Otherwise the model would be choosing layout.
6. **Slot paths.** *Assumption:* v1 fills top-level scalars and appends to top-level arrays only. Nested paths like `sources[i].quotes` wait until a real need appears.
7. **Footnote references inside model prose** (a model typing `[^1]`). *Assumption:* forbidden by `isInert`. References come from template slots only.
8. **Data errors versus template errors.** k4o render errors caused by data (for example, a table row width mismatch) currently get sent to template repair, which is the wrong layer. *Assumption:* the ratchet only ever adds values that pass the schema check. A follow-up should route data diagnostics separately (check whether k4o diagnostic kinds distinguish render-time from parse-time errors).
9. **What the boris site contains.** SPEC says "frozen boris site" without listing pages. *Assumption:* one stub page per source `id`, plus `apparatus` and `verdicts/`.
10. **Heading-ID agreement.** `[[apparatus#source-id]]` deep links need k4o's `kebab` slugs to match boris's heading-ID rules (`heading-ids.md`). This is unverified. Test it before you rely on it.
11. **dogbed wikilink resolution.** Oliver wikilinks need a resolver policy (`docs/WIKILINKS.md`), and dogbed has none yet. *Assumption:* `[[id]]` maps to `id.html`.
12. **The `store` sidecar.** Provenance (template and target for each `doc_id`) would help publish_check and the ratchet. *Assumption:* if added, it lives in `artifacts/meta/<doc_id>.json`, not next to the doc (F10).
13. **SPEC's command names** (`--fail-on-unlinked`, `search-index`, `source-rag`) don't exist in boris 0.8.2. *Assumption:* update SPEC as described in F6 and F9.
14. **Scope.** GAMEPLAN has no density or ratchet line items. Making the ratchet the headline (as README now pitches it) uses the Oct 27–28 capacity that was freed because the tools walk is already done.

## 5. Risks, ranked

1. **dogbed HTML apparatus (F5).** This is more than a dependency bump, it touches another repo, and the k4o pin is 55 commits behind. The bump may shift dogbed's fixture bytes. Hold to the Oct 29 cut-line.
2. **Arguments can't see loop variables (F1).** Without the k4o fix, per-source links and fragment links are impossible inside loops. The fallbacks (autolinks, top-level fragment slots) lower the template ceiling.
3. **Spark's JSON discipline** on enrich calls. Mitigations: the `null` escape hatch, fence stripping, the schema and inert guards, and `top_k` retries. Rejection counts become eval data rather than crashes.
4. **Gaming the score.** Saturation, the coverage band, the noise penalties and `isInert` cover the known attacks. Run the confetti class before every freeze.
5. **Calibration drift.** Freeze `density/1` before the matrix run. Retuning means bumping the version and rerunning.
6. **boris strictness** (F7, F8) breaks the happy path until templates v2 lands. It also gives the hallucinated-link demo beat for free.

## 6. Small fixes to bundle into the first density PR

- `writeOutcome` should take the target's file extension (F10).
- Pass curl's payload and auth through files (F10).
- Add engine paths to the Makefile `eval` target (F11).
- Make formatcheck's line helpers `pub` for reuse.