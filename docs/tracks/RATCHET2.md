# RATCHET2 lane notes — #76: ratchet slots on the verdict + apparatus shapes

`docs/tracks/RATCHET.md` is #82's lane file; this is the second RATCHET lane,
so the file follows the `CI`/`CI2` suffix convention.

## What landed

| Path | What |
|---|---|
| `templates/shapes/verdict.json` | `apparatus`/`max_items`/`words` on `tags`, `related`, `blockers`, `caveats`, `receipts`, `sources`, `apparatus_page`; `evidence` on `receipts[].evidence`; `ref: footnotes` on `receipts[].note` |
| `templates/shapes/apparatus.json` | `apparatus`/`max_items`/`words` on `verdict_page`, `receipts`, `caveats`; `ref: footnotes` on `receipts[].note` |
| `eval/ratchet-mock.json` | `templates.verdict` + `templates.apparatus` canned values; every wikilink/embed names a page that exists in `boris-site/` |
| `eval/ratchet.json` | `verdict-min` (`min_gain 15`) and `apparatus-min` (`min_gain 10`, `stop stalled`) cases |

## Slots annotated, and why

v1 supports empty top-level scalars and appends to top-level arrays; a field
is a slot iff it has `apparatus` and is `optional` (or bounded by
`max_items`).

verdict:

| field | slot | apparatus |
|---|---|---|
| `tags` | `tags[+]` | frontmatter (`max_items 5`, `words 1` — copied from release-notes) |
| `related` | `related[+]` | wikilink (`max_items 3`, `words 3` — copied) |
| `blockers` | `blockers[+]` | list (`max_items 3`, `words 6`) |
| `receipts` | `receipts[+]` | table (`max_items 3` — the sample data has 3 rows) |
| `caveats` | `caveats[+]` | list (`max_items 3`, `words 6`) |
| `sources` | `sources[+]` | wikilink (`max_items 4`, `words 4`) — not in the issue's candidate list but it is an optional top-level `array<object>` v1 can grow; a grown source is a real citation (ledger + wikilinks + link). Mock appends "AcmeDB docs — architecture", a real boris page the min data does not cite |
| `apparatus_page` | `apparatus_page` | embed (`words 4`) |

`receipts[].evidence` is `evidence`-gated: the cell is the table's
verbatim-quote column, so appended rows must quote the data's source pool —
the mock rows quote all three `verdict.min.json` quotes. `receipts[].note`
gets `ref: footnotes` (integrity annotation; `verdict.min.json` has no
`footnotes`, so the mock rows omit `note` — a model-invented key now fails
at schema instead of format_check).

`words` on `blockers`/`caveats`/`receipts` is set to 6/6/4, not the
12/12/8 the values actually carry: the stub exists to rank probes and to
compute the ceiling, and apparatus gain is structural (callout/table), not
word-count. Smaller stubs under-guess, so the ceiling the loop chases stays
below what real values reach — the min run converges instead of hitting the
iteration cap one step short. (`receipts` real rows also carry the optional
`source`/`confidence` fields the stub skips, so real rows outgain stubs.)

apparatus:

| field | slot | apparatus |
|---|---|---|
| `verdict_page` | `verdict_page` | wikilink — fills the frontmatter `verdict` back-link and the "receipts behind" line |
| `receipts` | `receipts[+]` | table (`max_items 3`; `note` → `ref: footnotes`) |
| `caveats` | `caveats[+]` | list (`max_items 3`) |

## Skipped fields, and why

- `pull_quote` (verdict): `type: object` → kind `other`; v1 never fills
  objects. The issue flags it explicitly.
- `sources[].quotes` (both shapes): nested array inside an array item — v1
  only writes top-level. The issue flags it explicitly. (A `quotes` array in
  a `sources[+]` value is also rejected by schema: `checkSchema` runs
  `checkString` on every sub-field, so the mock source carries no quotes.)
- `footnotes` (both): `object<string,string>` → kind `other`; a footnote
  needs a nested write. Annotating it would be inert decoration.
- verdict `subject`/`date`/`gaf` and apparatus `subtitle`/`date`: optional
  scalars the ratchet could technically fill, but they aren't apparatus —
  `subject` rewrites the page slug, `date`/`gaf`/`subtitle` add no link,
  table, list or callout. None are in the issue's candidate list.
- `apparatus_page` on the apparatus shape: it is the page's *own* name
  (heading fallback), not an apparatus slot.
- apparatus `sources`: required, and the issue scopes this lane to
  "growable optional fields" — `verdict.sources` is optional and annotated;
  bounding `apparatus.sources` with `max_items` (like reading-note `quotes`)
  is a reasonable follow-up.
- `verdict_page` gets **no canned value** in the mock: on
  `verdict.min.json` data the heading falls back to `title` ("Verdict:
  AcmeDB"), so the only correct value equals the heading and is a guaranteed
  `no-gain`; declining is the honest answer and exercises that path.

## The climb (measured)

`ratchet verdict -d data/verdict.min.json --backend mock`:

```text
stop ceiling   start 24.2 -> final 65.1 (ceiling 62.0)   5 iters, 5 calls
steps: apparatus_page +10.2, receipts[+] +12.9, sources[+] +3.4,
       receipts[+] +7.2, receipts[+] +7.2
```

Before the slot work the same command was `0/0` slots, `ceiling` at 24.2.
The gain beats the ≥15 / ≤6-iterations gate by a wide margin.

`ratchet apparatus -d data/verdict.min.json --backend mock` (the
apparatus-min case):

```text
stop stalled   start 34.9 -> final 54.7 (ceiling 61.1)   6 iters, 8 calls
steps: receipts[+] +4.7, caveats[+] +4.7, +4.4, +3.4,
       verdict_page declined -> receipts[+] +2.7,
       receipts[+] no-gain (-3.7, dilution) -> verdict_page declined
```

## Stop reasons in the new rows

- `verdict-min` — `ceiling`: after the 5th accept the best score is within ε
  of the 6-step stub ceiling (65.1 ≥ 62.0 − 1.0 at the next iteration check).
- `apparatus-min` — `stalled`: both asks in iteration 6 fail: a third
  claim-map row *loses* points (probe +3.7, real −3.7 → `no-gain`, the
  dilution guard working) and `verdict_page` declines (its only honest value
  equals the heading). Earlier iteration 5 spent one call on the
  `verdict_page` decline, then `receipts[+]` accepted.

The corpus's one pre-existing red row is `plateau-dilution`
(`stop ceiling, want plateau`) — tracked and being fixed in #114, not
in this lane's files.

## publish-check: one pre-existing dangling link

`knap-mcp publish-check <final verdict-min doc>` reports exactly one
diagnostic, `EREFERENCEMISSING` on
`[[AcmeDB issue #412 — cross-region replication]]`. That source name is in
`data/verdict.min.json` (and `data/verdict.full.json`) — the `#` is parsed
as a wikilink fragment separator, so the staged target becomes
`acmedb-issue`, which is not a page. The raw `render verdict` of the min
data fails the same way, so this is a data hazard, not something the
ratchet introduced; every wikilink/embed value the mock adds resolves.
The fix (drop the `#` from the source `name`, or handle `#` in
`stage`/`slug`) touches files outside this lane — filed as #124 and
flagged in a comment on #76.

## Left for later lanes

- `ratchet-eval` does not run under `make eval` (that target is the repair
  corpus); the ratchet table above is `knap-mcp ratchet-eval --backend mock`.
- A live backend can invent page names for `sources[+]`/`related[+]`/
  `apparatus_page`; the shape `role` text already warns, and publish-check
  is the backstop. `sources[+]` has the largest invention surface
  (name + url + rel + reliability + gaf) — worth watching in the model
  matrix lane (#91).
