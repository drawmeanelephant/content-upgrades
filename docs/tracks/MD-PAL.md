# MD-PAL lane notes

Block palette (#232): server-picked block kinds the ratchet can climb.
Verified on the pinned engines (k4o `aeba163`, dogbed `d96b125`), mock
backend.

## Decision

**The server picks the kind, never the model.** A palette extends the
ratchet's core invariant ("the server picks the slot") one level down: a
palette slot is expanded into one candidate per kind, every candidate is
probed with a stub like any other slot, and the scorer's gain decides.
The model is handed exactly one kind and that kind's fields. A reply that
names another kind, or fills a field another kind uses, is a `schema`
rejection, the same class as an out-of-shape enum. The layout of every
kind stays in the template's `{% if s.kind == "..." %}` chain, which the
model never sees.

## Shape extension

On an `array<object>` field with `"apparatus": "palette"`:

```json
"variant": "kind",
"variants": {"steps": ["title", "items"], "code": ["title", "command"], "quote": ["text"]}
```

`parseShape` returns `error.BadShape` unless:

- `variant` names an item field that is a required string with an enum,
  and the enum has no duplicates
- the `variants` keys and the enum match exactly, both ways
- every listed field is an item field and isn't the variant field
  itself, and no kind lists a field twice
- every item field marked required is listed by every kind
- `palette` and `variant`/`variants` only appear together

A kind's listed fields are all **required** for that kind. A kind may
list no fields at all (e.g. a `rule` divider).

Two item-field annotations came with this work, both general:

- `"apparatus": "code"` on an item field gives it the #228 code rules:
  the literal-safe `codeInert` rule and the exact-substring
  `codeVerbatim` evidence gate. That gate always runs, even with
  `--verifier none`. A code field must be `string` or `array<string>`.
- `max_items` on an `array<string>` item field is enforced by
  `checkObject` (`items: max_items: 5 > 4`). Before this, nested arrays
  were unbounded. No shipped shape sets it on an item field, so every
  existing row is unchanged.

## Probing: cost and cap

A palette with K kinds costs `min(K, max_variant_probes)` probe renders
per iteration instead of 1, and `stubCeiling` pays the same per step
(it calls the same `probeAll`, so the ceiling is the loop's own policy).
Renders are not backend calls. Every ask of a palette kind spends one
call from the same `max_backend_calls` budget as any other slot. Variant
candidates also share the one `top_k` ask slice, so a rejected kind can
be retried with the next-best kind, or with another slot, in the same
iteration.

**Cap: `max_variant_probes = 3`, in a round-robin window.** At step `t`
the window covers kinds `(3t + j) mod K` for `j < 3`, in enum order. On
a four-kind palette that gives `{0,1,2}`, `{3,0,1}`, `{2,3,0}`,
`{1,2,3}`. Why this window:

- *Deterministic and stateless.* The window depends only on the step
  index, so `stubCeiling` replays exactly what the loop will do.
- *Can't starve a kind.* Every kind is probed within `ceil(K/3)`
  iterations.
- *Last gain would starve kinds.* Ordering by last gain locks out any
  kind whose first probe happened on a short doc. Below `min_words`, the
  length factor shrinks every gain, so early probes systematically
  understate a kind's value. A kind's variety credit also only changes
  when *other* kinds land, and a stale gain can't see that.
- *Three, not two.* With 3, consecutive windows on a four-kind palette
  overlap by two kinds. Each step, the window holds a kind already on
  the page alongside new ones, so the variety gradient picks, not the
  cursor. (With 2, consecutive windows would be disjoint, and "distinct
  kinds" would follow from the cursor alone.)

## Asking

The slice for a picked kind:

```
FIELD: sections[+]:code   (append one item)
SCHEMA: {"type":"object","fields":{"kind":{"type":"string","role":"block kind; the server picks it, copy it as given","enum":["code"]},"title":{"type":"string","role":"section heading, one short line","words":4},"command":{"type":"string","role":"one shell command, copied verbatim from a source, rendered in a code block","apparatus":"code","max_words":20}}}
KIND: code   (chosen by the server: set "kind" to "code" and fill only the fields in SCHEMA)
Field 'command' is rendered verbatim inside a code block: copy the command exactly from EVIDENCE, one line, no backtick fences. Pipes and symbols are fine here.
ROLE: one block of the page, of the kind the server chose
HEADLINE: {"title":"Restoring an AcmeDB snapshot"}
EVIDENCE: [...]
```

`enrich_prefix` is unchanged, so it stays cacheable. The step label and
the mock key are both `name[+]:kind`.

## Eval harness

- `ratchet-eval` cases accept `max_calls` (0 to `max_backend_calls`), a
  tighter per-case call budget. `Options.max_calls` defaults to
  `max_backend_calls`, so the MCP tool and CLI behave as before. The
  budget check is now `calls >= max_calls` (it was `== 10`).
- Fixture `eval/ratchet/palette.{knap,shape.json,data.json}`: a short
  restore runbook. Its `sections` palette has four kinds: `steps`
  (`list:numbered`), `checklist` (`list:task`), `code` (`code_block:"sh"`,
  code-gated) and `quote` (`blockquote`, evidence-gated). `max_items` is
  3.
- The fixture intro is ~200 words, hard-wrapped to 17 lines.
  `min_words` scaling would otherwise flatten every gain, as MD-RT1
  found. The wrap is there because format_check's `list-heavy` compares
  list *lines* to prose *lines*: a one-line intro made the first
  4-item list a new warning, so the loop rejected it.

## Step trace: `fixture-palette`

The `ratchet-eval` report (`knap://docs/<id>.ratchet.json`), steps:

```
{"iteration": 1, "slot": "sections[+]:steps", "probe_gain": 7.7, "gain": 7.7, "accepted": true, "reason": "ok"}
{"iteration": 2, "slot": "sections[+]:quote", "probe_gain": 4.0, "gain": 3.9, "accepted": true, "reason": "ok"}
{"iteration": 3, "slot": "sections[+]:code",  "probe_gain": 4.1, "gain": 4.1, "accepted": true, "reason": "ok"}
```

start 5.3, final 21.0, ceiling 21.0, stop `ceiling`, 3 calls, 22
renders (9 of them for the ceiling).

Every probe the loop rendered, captured once with a temporary print and
then removed. The probe gains show the gradient doing the choosing:

| iter | window | probe gains | server pick |
|---|---|---|---|
| 1 | steps, checklist, code | 7.7, 7.7, 6.7 | `steps` (tie with checklist; lower kind index wins) |
| 2 | quote, steps, checklist | 3.9, **0.0**, 1.0 | `quote` |
| 3 | code, quote, steps | 4.1, **−0.1**, **0.1** | `code` |

A second item of a kind already on the page earns ~0, because
`block_variety` counts distinct kinds. A new kind earns its own signals
plus a variety step. In iteration 2 the repeat `steps` probes 0.0 while
the new `checklist` probes 1.0. In iteration 3 both repeats sit below
epsilon, so they would never be asked.

## Cases

| case | what it shows | result |
|---|---|---|
| `fixture-palette` | 3 accepted items, 3 distinct kinds | `ceiling`, gain 15.7 |
| `adv-palette-kind-swap` | the `steps` reply sets `"kind": "checklist"` | `schema` 1 (`variant: kind must be 'steps', the server's pick`); the retry slot `sections[+]:checklist` is accepted in the same iteration |
| `adv-palette-budget` | `max_calls: 1`, the `steps` ask declines | iter 1 probes steps/checklist/code, asks `steps` (declined), stops `budget` before the retry. The loop never probes `quote` and no call is spent on it |

`stubCeiling` does render a `quote` stub (step 1 of the ceiling climb),
since the ceiling is computed before the loop. That spends renders, not
calls, so it doesn't count against the budget.

## Gate output

- `make test`: all 248 tests pass, 7 of them new `ratchet.test.palette:*`.
- `make ratchet-eval`: all expectations met. Diffed against `main`
  (`a5e4430`) with the `ms` column masked: every existing row is
  byte-identical. Only the three new rows and the aggregate `calls:`
  line (108 → 116) differ.
- `make eval`: unchanged (it doesn't touch the ratchet).
- `zig fmt --check src`: clean.

## What other lanes must know

- `Apparatus` gained `palette`. Nothing outside `ratchet.zig` switches
  on it.
- `Slot` gained `variant` / `variants` / `chosen` and `Slot.pick(k)`.
  Code that walks `shape.slots` sees one palette slot, never its kinds.
  Go through `pick` (or `Cand.of`) to get a kind's fields, schema and
  path.
- Step labels for palette asks are `name[+]:kind`. Mock tables key
  palette values the same way.
- Adopting the palette in a shipped template (e.g. a runbook appendix)
  is out of scope here. It's filed as #270.
