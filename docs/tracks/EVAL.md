# EVAL: eval corpora, fixtures, and expectations

## Issue #114 — plateau-dilution (landed)

`plateau-dilution` stopped `ceiling` under density/2 because the scorer's
new `min(1, words/200)` positive-credit scale changed what the stub climb
sees: `stubCeiling` climbs with short stub values, so the fixture rendered
under the word floor and the ceiling collapsed to 44.1 (density/1: 56.5).
The 167-word `box` mock reply then pushed the real run's length scale to
full credit and the run crossed the stub ceiling after only 4 accepts.

Fix: `eval/ratchet/ladder.data.json` `intro` is now ~200 words of plain
prose. Every render — stub climb included — sits above the floor, so the
ceiling is 54.8 and the diluted run stalls at 45.6 with every remaining
probe below eps: a genuine `plateau`, not a re-labeled `ceiling`.

**Load-bearing:** keep `intro` at ≥ ~200 words (the scorer floor is
`min_words = 200`). Shortening it drops both ladder cases (`budget-burn`
shares the data file) back under the word floor and re-breaks this case.
The `intro` is prose only, so it adds no apparatus to the start state.
