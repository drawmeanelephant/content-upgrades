# RATCHET: footnotes as a ratchet step (#83)

## What landed

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

## Numbers (mock, k4o pin `aeba163`)

`ratchet release-notes -d data/release-notes.min.json --backend mock`:
39.2 → 82.5 (was 71.3), ceiling 82.8 (was 71.2). Step 2 is `notes{+}`,
gain +14.1, accepted, no new warnings. Two runs give byte-identical data,
doc and result JSON once `ms` and the timestamped artifact ids are removed.

New ratchet-eval rows on `eval/ratchet/footnotes.*`: `fixture-footnotes`
(both notes land), `adv-dangling-ref` (schema), `adv-model-picks-key`
(schema), `adv-footnote-markup` (inert), `adv-footnote-paraphrase`
(verifier).

## For other lanes

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
