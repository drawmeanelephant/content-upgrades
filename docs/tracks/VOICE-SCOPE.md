# VOICE-SCOPE — the voice guard is token-level; no new-word cap

Lane: issue #306 (audit finding 7). Decision: option (c), no rule. The
guard's real scope is now stated in `docs/SPEC.md`, `knap-mcp/README.md` and
`knap-mcp/prompts/voice/README.md` ("The guard" → Scope).

## The limit

`voice.guard` verifies tokens: fact-shaped tokens (numbers, URLs, names,
quotes, footnote refs, wikilinks), markup in both directions, inline
structure, length, overlap. It does not verify meaning. Both of these pass
every hard rule and every tone budget (`strict()`), on main and after this
lane:

| input | reply | why it passes |
|---|---|---|
| `the boring database ships every release on schedule` | `the boring database ships on schedule; vendor recalled units, refunded buyers` | lowercase words are never facts; 4/6 input content words kept |
| same | `the boring database never ships on schedule` | negations aren't content words; 4/6 kept; zero new words |

`voice.zig`'s test `guard scope: plain-word claims and negation flips pass
(token-level only)` pins both, plus a control (`recalled 400 units` fails on
the added number). If a semantic check ever lands, that test flips and the
three scope statements must change with it.

## Measurement

Metric: reply content words (`contentWords`/`contentwords`: normalized,
stopword- and negation-free, stemmed) that share no stem (`sameStem`, so
`shipped`~`ships`) with any input content word. Ratio = new / input content
words, over inputs with ≥3 content words (the overlap rule's floor).
Measured with the awk mirror over every shipped line (one-off script, not
committed).

| set | n | mean | median | p90 | max | max ratio |
|---|---|---|---|---|---|---|
| examples/mild | 12 | 1.25 | 1 | 2 | 4 | 0.40 |
| examples/spicy | 12 | 2.67 | 2 | 4 | 4 | 0.50 |
| examples/feral | 12 | 4.75 | 5 | 7 | 8 | 1.00 |
| mock/mild | 80 | 1.32 | 1 | 2 | 5 | 0.75 |
| mock/spicy | 80 | 1.65 | 1 | 3 | 5 | 1.00 |
| mock/feral | 80 | 2.54 | 2 | 5 | 7 | 1.40 |
| eval/doc-voice/replies | 4 | 0.25 | 0 | 1 | 1 | 0.09 |
| **repro (spicy)** | 1 | | | | **5** | **0.83** |
| **negation flip** | 1 | | | | **0** | **0** |

Overall histogram (276 shipped lines + 4 doc-voice): 0→23, 1→111, 2→78,
3→28, 4→20, 5→11, 6→4, 7→4, 8→1.

`make voice-eval` replays exactly `mock/*.jsonl` through `knap-mcp voice
--backend mock`, so its distribution is the mock rows above. The doc-voice
eval's only passing reply adds 0 words (the one with 1, `0002`, is a
rejected case that fails on the wikilink).

Largest shipped values, all legitimate voice — imagery, not claims:
`board red conspiracy like all str sourc` (feral subtitle, 7 new / 5 input),
`twist gorgeou shop need gift actually knob goddamn` (feral summary, 8/24),
`get wet quit bucket like` (feral take, 5/5), `infra rarest flex somehow`
(spicy take, 4/4), `anyway anywher notic everyon trend` (mild, 5/14).

## Why no rule

- (a) Hard cap: any threshold that rejects no shipped example or mock is
  ≥8 absolute (≥5 per-tone even for mild) or ≥1.40 ratio (≥1.00 for
  spicy). The repro is 5 new words, ratio 0.83, in spicy: it passes every
  such cap. A per-tone cap tight enough to catch it would reject shipped
  spicy/mild voice.
- (b) Advisory: budgets are failures in `check.sh`, so the same thresholds
  apply, and the same repro slips under them. The only sliver — a mild
  ratio cap at 0.75 — would catch this repro only in mild, with a 0.08
  margin, and `vendor recalled units` (3 new, 0.50) slips under it.
- Above all, the count measures the wrong thing. The negation flip adds
  zero words and inverts the claim; one word (`rarely`) can do the same.
  A count cap would give a false sense of a semantic check while taxing
  the feral tone, whose job is exactly to add words.

So: the scope is documented as a runtime limit, review notes cover the
examples, and meaning stays with the prompt and the human reviewer.
`knap_verify_citation` is the existing hook for claim-level checks if a
semantic guard is ever wanted.

## Files

- `docs/SPEC.md` — "Nothing ships unverified" qualified to the token level;
  one sentence on the `knap_voice` paragraph.
- `knap-mcp/README.md` — the line-10 claim, same qualification.
- `knap-mcp/prompts/voice/README.md` — Scope paragraph under "The guard";
  the review note now says "here or at runtime".
- `knap-mcp/src/voice.zig` — the scope test only; guard unchanged.
- `voice.awk`, `testdata/bad.jsonl` — untouched (no rule, nothing to mirror).

## Gates

`make test` 267/267; `make eval` converged 120/167, controls 2/2 clean
(unchanged — no runtime code changed); `make voice-eval` pass, 15
template × tone runs matched; `check.sh` 36 examples, 240 mock, 50/50
selftests, 0 warnings, 0 failures; `eval/doc-voice/run.sh` all passed.
