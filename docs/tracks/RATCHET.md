# RATCHET lane notes

## #79 — sub-epsilon ask gate

`askSlice(cands, eps)` now decides which probes earn a backend call:
ranked best-first by `candLess`, capped at `top_k`, and trimmed of any
gain below `eps`. `run` asks exactly that slice; an empty slice is the
`plateau` stop (same semantics as the old `cands[0].gain < eps` check).

Mock eval delta (`ratchet-eval --backend mock`, density/2):

- `adv-verifier-paraphrase`: calls 5 -> 4, declined 2 -> 1 (the gain-0
  `callouts[+]` retry is no longer asked; the mock has no reply for it).
- `adv-no-gain-wall`: calls 6 -> 5, no-gain 2 -> 1, renders 76 -> 75 (the
  sub-eps retry's post-write render is skipped too).
- All other rows unchanged; every expectation still holds.

Pre-existing failure, unrelated: `plateau-dilution` expects stop `plateau`
but density/2 (#72) makes the case converge to `ceiling`. Fails on clean
main too; filed as #114.

## #82 — `evidence:"boris"` (#111)

- `ratchet.Options.evidence: ratchet.Evidence` (`data` | `boris`, default
  `data`). `run()` picks the pool once, at `Run` construction: `data` keeps
  `dataEvidence` (`data.sources[*]` quote/text/string); `boris` loads the
  artifact via `borisrag.load` (same path as `tools/boris_ask.zig` —
  `KNAP_BORIS_SITE`, else `<templates>/../../boris-site`) and takes
  `borisrag.ask` snippets for `subject ?? title`, `limit = 5`,
  `claims_only = false`. Missing subject and title fails the run before
  any render.
- `knap_ratchet` schema enum is now `["data","boris"]`; anything else is a
  `ToolFailed` naming both valid values.
- `--evidence` was already in `tool_flags` (verify-citation added it), so
  `knap-mcp ratchet <id> -d f.json --evidence boris` needed no flag work;
  the one shared `usage_tail` line now covers both meanings.
- The boris pool feeds both the enrich slice (`EVIDENCE:` in
  `buildSlice`) and the verifier gate (`checkEvidence`), unchanged.
- Done-when test: `ratchet.zig` test "boris evidence" — a fixture
  artifact's snippet is accepted verbatim on an evidence-gated slot and a
  paraphrase is rejected by `checkEvidence` (heuristic).
- No ratchet-eval corpus support for `evidence` (kept the diff tight —
  other lanes own the eval region); the unit test carries the gate.

Gates: `make test` green; `KNAP_MCP_HOME=$(mktemp -d) make eval` green
(120/167 converged, same as baseline). Smoke:
`ratchet reading-note -d data/reading-note.min.json --evidence boris`
runs to `max_iterations` with hits on "The Machine Stops".

## #83 — footnotes as a ratchet step

### What landed


- **Keyed slots.** `object<string,string>` (and `object<string>`) fields
  parse as `Kind.keyed`. One becomes a slot, path `name{+}`, only when it
  has an `apparatus` and some array<object> item field `ref`s it. A map
  nothing references would only add unused footnotes.
- **Paired write.** `withValue` on a keyed slot appends one key and, in the
  same write, sets the empty `ref` field of one existing element to that
  key. The server picks both:
  - the anchor is the first element, in shape order then data order, whose
    ref field is empty;
  - the key is the kebab form of the item's first required plain string
    field (at most 4 words and 32 bytes, so k4o's `kebab` leaves it
    unchanged), with `-2`, `-3`, … appended until it is unique; `note`
    when the label has no ASCII word.

  The model gets `ANCHOR: field[i] {…}` in its slice and returns only the
  note text. An accepted step's `detail` records the write, e.g.
  `highlights[0].note=point-in-time-snapshots`.
- **Gates on the note text.** Schema (must be a string; an object that
  tries to name its own key gets `expected a string`), `isInert` (so
  `[^1]` in the text is rejected), and the verifier when the map is
  `evidence: true`.
- **Ref integrity.** `refCheck(shape, data)` is the document-level check:
  every non-empty ref must name a key, and every key of a referenced map
  must be named by some ref. The loop rejects a candidate as `schema` when
  `best` is ref-clean and the candidate is not. The existing per-value
  `ref` check in `checkSchema` still runs first, so a dangling `note` on an
  appended item fails with `ref: note '…' is not a key in 'notes'`.
- Shape annotations: the `notes` role in `release-notes` and `reading-note`
  now tells the model that the server picks the key and the anchor.

### Numbers (mock, k4o pin `aeba163`)

`ratchet release-notes -d data/release-notes.min.json --backend mock`:
39.2 → 82.5 (was 71.3), ceiling 82.8 (was 71.2). Step 2 is `notes{+}`,
gain +14.1, accepted, no new warnings. Two runs give byte-identical data,
doc and result JSON once `ms` and the timestamped artifact ids are removed.

New ratchet-eval rows on `eval/ratchet/footnotes.*`: `fixture-footnotes`
(both notes land), `adv-dangling-ref` (schema), `adv-model-picks-key`
(schema), `adv-footnote-markup` (inert), `adv-footnote-paraphrase`
(verifier).

### For other lanes

- `reading-note` now has a `notes{+}` slot too. Its sources only hold the
  story's quotes, so the mock declines it. `reading-note-min` now stops on
  `budget` (66.1, 5 declines) instead of `max_iterations` (67.8); its
  `min_gain` expectation still holds. Give it a canned note once the data
  has a source that can back one.
- `plateau-dilution` already failed on `main` before this change (stop
  `ceiling`, want `plateau`). It is not part of `make eval`.
- `demo/storyboard.md` 4b quotes the old numbers (71.3 / 71.2, 4/8 slots).
  The new run fills 5 of 9 slots.
- Templates: in `release-notes.knap`, the `{% if not loop.last %}`
  separator gives no blank line between highlights (`…[^key]\n### Next`).
  This predates #83. An ATX heading still interrupts the paragraph, so
  scores are unaffected.
- `verdict` / `apparatus`: their `footnotes` maps have no `apparatus`, and
  nothing `ref`s them. Once a template adds `[^{{ x.note | kebab }}]` sites
  and a `ref` annotation, they become `footnotes{+}` slots with no code
  change.

## #377 — grounding contract for extracted records

Extracted filed records (`extra_sections`/`card` in the data, or
`--evidence record`) now run the ratchet under a grounding contract:

- Pool = `recordSpans`: every string in the data (card, extra_sections,
  canon values, fm scalars, `sources` quotes — it subsumes
  `dataEvidence`).
- Slice gets a `GROUND:` line: compose only from quoted/near-quoted
  spans, return null if nothing supports the field. `enrich_prefix` is
  unchanged.
- Pre-ask skip: `groundedWhy` requires a span sharing a topic word
  (slot name + canon `section`, singular/plural) — no match means the
  record is deliberately lacking, so the step is `ungrounded` with a
  reason, costing no call. `declined` still means asked-and-null.
- Post-reply gate `groundedViolation` (reason `verifier`): every prose
  sentence must be `entails`|`neutral` vs the pool; url/page strings an
  exact substring; enum/ref/code fields follow their own gates.
- The ask loop scans the whole above-eps ranked list until `top_k` asks
  are spent (`rankSlice`), so skips and asks interleave in `steps`.
  Report gains `"grounded": true|false` and an `ungrounded` column in
  ratchet-eval.

Verified live (`devin acp --model swe-2-medium`) on an extracted
mascot record: 6 calls, 6 accepted fills, 0 declines, `system_messages[+]`
skipped `ungrounded` (no topical span). Eval: `fixture-record-grounded`,
`fixture-record-ungrounded`, `adv-record-fabrication` + mock table
`filed-mascot`.
