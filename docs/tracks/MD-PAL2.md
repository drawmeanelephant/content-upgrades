# MD-PAL2 lane notes

Runbook appendix palette (#270): the first shipped template adopts the
#232 block palette. Verified on the pinned engines (k4o `aeba163`,
dogbed `d96b125`), mock backend.

## What landed

- `templates/runbook.knap`: an `{% if appendix %}` loop between the
  lesson block and `See also`, inside the same guard idiom as the other
  optional blocks. Each item's `kind` is server-picked; the if chain
  renders `checklist` as `list:"task"`, `steps` as `list:"numbered"`,
  `code` as `code_block:"sh"` and `quote` as a bare `blockquote`.
  Checklist/steps/code items get an h2 `title`; quote has none — same
  split as `eval/ratchet/palette.knap`.
- `templates/shapes/runbook.json`: `appendix` as an optional
  `array<object>` with `"apparatus": "palette"`, `max_items` 3,
  `variant: "kind"`, and the four variants. `command` carries the
  item-level `"apparatus": "code"` (literal-safe inert + exact-substring
  verbatim gate) and `text` carries `evidence: true`.
- `data/runbook.min.json`: a `sources` array — the first one on this
  data file. The code and quote gates need evidence; `command` is an
  exact substring of a source quote and `text` is a whole source line.
- `eval/ratchet-mock.json`: one canned item per `appendix[+]:<kind>`
  path under `runbook`, matching the palette fixture's mock shape.
- `eval/ratchet.json`: `runbook-min` `min_gain` 20 → 40.

## Step trace: `runbook-min`

```
{"iteration": 1, "slot": "escalation[+]",        "probe_gain": 11.8, "gain": 9.9,  "accepted": true}
{"iteration": 2, "slot": "danger",               "probe_gain": 13.2, "gain": 11.3, "accepted": true}
{"iteration": 3, "slot": "appendix[+]:checklist","probe_gain": 12.9, "gain": 11.6, "accepted": true}
{"iteration": 4, "slot": "appendix[+]:quote",    "probe_gain": 6.2,  "gain": 8.7,  "accepted": true}
{"iteration": 5, "slot": "escalation[+]",        "probe_gain": 4.4,  "gain": 2.4,  "accepted": true}
{"iteration": 6, "slot": "escalation[+]",        "probe_gain": 1.8,  "gain": 2.0,  "accepted": true}
```

start 23.6, final 69.6, ceiling 69.6 (was 37.1 / 65.5), stop
`max_iterations`, slot_fill 3/9 (was 3/8).

Two appendix items land: a checklist at iter 3 — it out-probed
`preflight[+]` for the same task-list niche — and a verbatim quote at
iter 4. The min doc ends at its own ceiling (every remaining candidate
probes under epsilon), but the loop still stops on the iteration cap
because the cap fires first.

## `min_gain` 20 → 40

Measured gain is 46.0. The floor went to 40 rather than 46 for the same
reason the other floors sit under their measured values: it is a floor,
not a measurement, and mock tables elsewhere in the corpus evolve. What
raised it is honest: two accepted appendix steps worth ~20 points
between them replaced ~11 points of escalation/danger/preflight climb,
and the palette made the doc's ceiling reachable (69.6 vs an
unreached 65.5 before).

## `list-heavy` watch

The worry from the issue was real but did not fire. format_check's
`list-heavy` counts list lines vs prose lines (callout bodies and
blockquotes count as prose; fence interiors count as neither). The min
doc opens at prose 3 (meta line + abstract callout's two `>` lines).
The accepted sequence stays on the safe side the whole way:

| iter | lands | list | prose |
|---|---|---|---|
| 2 | danger callout | 0 | 5 |
| 3 | checklist (3 items) | 3 | 5 |
| 4 | quote blockquote | 3 | 6 |

`warnsSubset` means *no* accepted step can ever introduce the rule, so a
list-kind appendix item had to land while prose still had the lead —
checklist at iter 3 is exactly that window. Had `preflight[+]` (5 items)
been asked first it would have tied 5–5, which is still safe
(`list > prose` is the trigger, not `>=`), but a 4-item appendix list on
top of it would have been a `new-warnings` rejection. Kind order in the
enum (`checklist, steps, code, quote`) puts both list kinds in the iter-1
probe window; only one list item fit under the rule before quote/code
became the better asks anyway.

## Byte-identity check

`knap-mcp render runbook -d data/runbook.{min,sample}.json
--target {markdown,html}` captured before and after the template edit:
all four pairs `cmp`-identical. The `{% if appendix %}` guard emits
nothing when the field is absent, and `sources` is not a rendered field.

## Gate output

- `make test`: all 253 tests pass.
- `make eval`: converged 120/167, unchanged (doesn't touch the ratchet).
- `make ratchet-eval`: all expectations met. Every row except
  `runbook-min` is numerically identical to `main` (ms columns and the
  aggregate probe/slice lines aside). `runbook-min`: gain 46.0,
  accepted 6/6 calls, 0 rejections.
- `zig fmt --check src`: clean (no .zig files touched).

## What other lanes must know

- `runbook` now has a ninth growable slot; `appendix[+]:<kind>` mock
  keys live under the `runbook` template key like any other slot.
- `runbook.min.json` has `sources` now. Anything evidence- or
  code-gated on the runbook shape (`lesson`, `appendix` quote/code)
  verifies against them.
- The `runbook` description in the shape still doesn't mention the
  appendix; if a lane adds a shipped-template section about palettes,
  the shape `description` is the place.

## 2026-10-28 audit re-check

c305dd7 runbook-appendix claims from the 2026-10-28 audit — checked at
c305dd7, not reproduced: `command` max_words:20 rejects oversized input
as a schema error rather than silently truncating; `title` passes
through the inert-token gate; the `code_block:"sh"` command context is
covered by the code-field check plus the exact-substring evidence gate.
No issue filed.
