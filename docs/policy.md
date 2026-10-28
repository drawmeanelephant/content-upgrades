# knap-policy.json — per-collection scoring policy

Schema `knap-policy/1` (FILED-POL, #255). Code: `knap-mcp/src/policy.zig`.
Worked example: `knap-mcp/policy/filed.json`.

A corpus isn't one genre. A haiku that scores 6 on density is correct.
Give it a table and you've damaged it. A policy names collections by glob
and, for each one, says:

- which density signals count, which are exempt, capped or forbidden
- what score band a doc is expected to sit in
- the collection-mean floor that marks a regression
- where, if anywhere, a voice pass may touch the text

**Policy only judges.** It never edits a doc and never changes the raw
density total (`density/3` is still the scorer contract). It adds a
policy score next to the raw total and reports violations as data.

## Discovery

`knap-mcp audit <dir>` looks for a policy in this order:

1. `--policy <file>`
2. `$KNAP_POLICY`
3. `<dir>/knap-policy.json`
4. `<dir>/../knap-policy.json`, so a site can keep it next to `content/`

`--no-policy` turns discovery off. When a policy is in use, its path is
printed on stderr, because a discovered file changes the report.

## Schema

```json
{
  "schema": "knap-policy/1",
  "note": "free text (optional)",
  "collections": [
    {
      "name": "haikus",
      "glob": "haikus/**",
      "note": "free text (optional)",
      "signals": { "tables": "forbid", "links": "exempt", "footnotes": { "cap": 3 } },
      "score": { "min": 0, "max": 20, "mean_min": 6 },
      "voice": { "tones": [], "regions": [] }
    }
  ]
}
```

| key | type | meaning |
|---|---|---|
| `schema` | `"knap-policy/1"` | required; any other value is rejected |
| `note` | string | human rationale; ignored by tools |
| `collections` | non-empty array | checked in order; the **first** collection with a matching glob owns a doc |
| `.name` | string | unique; the rollup group name |
| `.glob` | string or array of strings | relative to the audit root; `*`/`?` match within a segment, `**` matches zero or more segments |
| `.signals` | object | signal name → rule (see below); omitted signals are `"score"` |
| `.score.min` | 0..100 | per-doc band floor. Under it, the doc is an upgrade candidate (`below`) |
| `.score.max` | 0..100 | per-doc band ceiling. Over it is an `above-band` **violation**: an over-upgraded doc |
| `.score.mean_min` | 0..100 | collection floor. A collection mean under it shows `drift` in the rollup (regression detection) |
| `.voice.tones` | array of `mild`/`spicy`/`feral` | tones a voice pass may use; `[]` denies voice |
| `.voice.regions` | array of `paragraphs`/`verse`/`list_items`/`headings` | regions a voice pass may rewrite; `[]` denies voice |

**Unknown keys are load errors**, and so are unknown signals, modes,
tones and regions, duplicate names or list entries, `min > max`, and
numbers outside 0..100. The error names the JSON path, e.g.
`policy p.json: collections[0].score: unknown key 'mean_max' (allowed:
min, max, mean_min)`. This follows filed's closed-frontmatter rule: a
typo must not quietly widen a policy.

### Signal rules

Signal names are the density spec ids: `callouts`, `footnotes`, `tables`,
`wikilinks`, `embeds`, `fragment_links`, `links`, `frontmatter`,
`code_fences`, `styled_runs`, `styled_coverage`, `emphasis_variety`,
`blockquotes`, `heading_levels`, `heading_density`, `lists`,
`block_variety`, `raw_urls`. `overload` isn't one: it's a meta-penalty
over the other signals.

| rule | scored? | violation? | use |
|---|---|---|---|
| `"score"` (default) | yes | no | normal |
| `"exempt"` | no. Its weight leaves the denominator, so being absent doesn't drag the score and being present earns nothing | no | apparatus that's neither expected nor harmful: an upgrade loop gets nothing for adding it |
| `"forbid"` | no. It earns no credit, and the score stays on the raw scale because the band already assumes it's absent | yes, on any occurrence | apparatus that damages the genre |
| `{"cap": n}` | yes | yes, if the raw count is over `n` | a ceiling that stops a runaway ratchet |

### Policy score

```
policy score = clamp( Σ⁺(scored) × 100 / (100 − Σ exempt positive weight)
                      + Σ⁻(scored), 0, 100 )
```

Σ⁺ is the sum of positive contributions from scored signals and Σ⁻ the
sum of their negative ones; format_check penalties are always scored.
With no exempt signals, and no forbidden signal present, the policy score
equals the raw total. Bands, `mean_min` and `--below` compare against the
policy score, and the raw total is reported next to it.

A forbidden signal that is present earns nothing itself. Side effects of
the same markup can still score, though: a table also adds to
`block_variety`. The `forbid` violation is the signal to act on, not the
score.

### Voice

The policy only declares what a voice pass may touch. The voice walker
(FILED-VOICE, #257) classifies the regions. `policy.voiceAllowed(coll,
tone, region)` is true only when the doc's collection declares a voice
block that lists both the tone and the region. So all of these deny voice:
no matching collection, no `voice` block, an empty `tones` list, or an
empty `regions` list. Verse (hard-broken lines: haiku, limerick stanzas)
is its own region, so a collection can allow `paragraphs` and still keep
its verse frozen.

## Audit report under a policy

- **JSONL rows** get a `policy` field:
  `{"collection":"haikus","score":10.44,"band":"in","violations":[{"rule":"forbid","signal":"tables","value":1.00,"limit":0.00}]}`.
  `band` is one of `in`, `below`, `above` or `unbanded`. A doc no
  collection matches gets `{"collection":null}`. Without a policy, rows
  are byte-identical to the policy-free format.
- **Rollup**: rows are grouped by collection. Docs no collection matches
  are grouped as `unpoliced:<default group>`, so they never mix with a
  policed collection. The mean/min/max/p25/p75 columns are policy scores.
  The added columns are `raw` (raw mean), `band`, `in`, `below`, `above`,
  `oop` (docs with at least one violation) and `state` (`drift` when the
  mean is under `mean_min`, `ok` otherwise, `-` when unpoliced).
- **`out of policy (N docs):`** is always printed. Each line is one doc
  with its violations (`forbid:tables=1`, `cap:footnotes=5>3`,
  `above-band=24.10>20.0`). A count of 0 means everything passed.
- **`--below band`** lists docs under their collection's `score.min`.
  **`--below <n>`** uses `n` only for docs whose collection sets no
  `score.min`: the genre's band wins over the global number. Each line
  shows the limit the doc missed.
- The exit code is 0 whatever the violations. Audit reports; it doesn't
  gate.
