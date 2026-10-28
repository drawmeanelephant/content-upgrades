# MD-RT2 lane notes

Wire the new template slots into the ratchet (#230). Everything below
verified on the pinned engines (k4o `aeba163`, dogbed `d96b125`),
mock backend.

## What landed

- `templates/shapes/release-notes.json` — annotation keys only:
  `preflight` list/4/6, `upgrade_steps` list/5/8, `upgrade_command`
  code/4 (verbatim-gated like every code slot), `rollback` callout/4/8.
- `templates/shapes/reading-note.json` — `epigraph` quote +
  `evidence: true` + `max_words 30`, `argument` list/5/12,
  `follow_ups` list/4/8. `thesis` stays unannotated (no highlight
  apparatus).
- `templates/shapes/runbook.json` — #227 shipped `preflight` list/6/15
  and `rollback` list/6/15. The issue table says list/5/6 and
  callout/4/8 (rollback renders inside the folded warning callout), so
  both were corrected to the table. `error_budget` stays unannotated
  (no math apparatus); nested `phases[].steps[]` untouched.
- `data/release-notes.min.json` / `data/reading-note.min.json` — one
  `sources` quote each: the release-notes one carries
  `acmedb upgrade --to 2.0.0` verbatim for the code gate, the
  reading-note one is the sample's epigraph line. `sources` isn't
  rendered; markdown and html renders of both files are byte-identical
  to `main` (`cmp` clean).
- `eval/ratchet-mock.json` — values for every newly annotated slot,
  plus a `notes{+}` value for reading-note (verbatim source quote) and
  the ungated runbook slots (`danger`, `tags`, `related`,
  `postmortem_url`, `escalation`) so `runbook-min` doesn't stall on
  declines. `lesson`/`notes{+}` for runbook stay unmocked on purpose:
  the min file has no `sources`, so they can't pass the evidence gate.
- `eval/ratchet.json` — new `runbook-min` (`min_gain 15`, measured
  28.0) and `adv-command-paraphrase` (reworded command → `verifier 1`
  via the code verbatim gate). `adv-no-gain-wall` retargeted, see
  below.
- `eval/density/` — re-rendered `release-notes.md` and
  `reading-note.md` (the upgrade-path, epigraph/thesis/argument and
  follow-ups sections landed after the fixtures were frozen; both
  `*.min.md` files were already current), added `runbook.md` /
  `runbook.min.md` and the README rows.

## ratchet-eval before / after (mock)

| case | before | after |
|---|---|---|
| release-notes-min | 43.5 gain, ceiling | 43.8 gain, ceiling |
| reading-note-min | 37.4 gain, budget | 55.5 gain, max_iterations |
| runbook-min | — | 28.0 gain, max_iterations |
| adv-command-paraphrase | — | verifier 1, ceiling |
| adv-no-gain-wall | no-gain 1, stalled | no-gain 1, ceiling |
| declines-stall | declined 3, stalled | declined 3, stalled |
| iteration-cap | accepted 2, max_iterations | accepted 2, max_iterations |
| everything else | — | unchanged |

Expectation changes and why:

- `adv-no-gain-wall` — same `{"reject": {"no-gain": 1}}` expectation,
  but the wall moved off `known_issues[+]`. With four new slots in the
  candidate pool the min run reaches ceiling before `known_issues` is
  ever probed in top-2, so the old mock value was never consumed
  (`no-gain 0`, stop `ceiling`). The wall now sits on
  `upgrade_steps[+]` (words 8 → 128-word cap; the wall is 103 words),
  a slot the loop does ask, and still rejects `no-gain`.
- No other expectations changed: `declines-stall` still stalls with 3
  declines and `iteration-cap` still caps with 2 accepted.

## Step trace — new slots accepted

`ratchet release-notes -d data/release-notes.min.json --backend mock`
(stop `ceiling`, score 38.0 → 81.8):

```
it1  upgrade_matrix[+]  probe 14.4  gain 14.7  ACCEPTED
it2  notes{+}           probe 14.1  gain 13.7  ACCEPTED
it3  related[+]         probe  6.8  gain  6.8  ACCEPTED
it4  upgrade_steps[+]   probe  4.4  gain  4.6  ACCEPTED   <- new slot
it5  upgrade_command    probe  4.0  gain  4.0  ACCEPTED   <- new slot
```

`ratchet reading-note -d data/reading-note.min.json --backend mock`
(stop `max_iterations`, score 31.0 → 86.5): `epigraph` accepted at
iteration 5 (probe 6.9, gain 10.6); the `notes{+}` mock also lands at
iteration 2 (`quotes[0].note=imagine-if-you-can`).

`ratchet runbook -d data/runbook.min.json --backend mock`
(stop `max_iterations`, score 8.8 → 36.9): `preflight[+]` accepted at
iteration 6 (gain 6.7). `escalation[+]` dominates the early probes on
a 40-word doc; `lesson` declines every time it's probed (no sources,
evidence-gated) but the run clears `min_gain 15` before it matters.

## Spec deviation — runbook in the density fixture test

The issue asked for `runbook` in the min-vs-sample template list with
every assertion green. `runbook.min.md` scores **8.8**; `generic.md`
scores **17.8**, so `generic < min` cannot hold — a required-fields
runbook is a 40-word skeleton, and ~90+ rendered words would be needed
to beat generic. `data/runbook.min.json` is not this lane's file, and
the test's assertions were off-limits ("extend only the template
list"), so `runbook` is left out of the list. Filed #241
(agent:advanced) for the design call: enrich the min data and re-tune
the `runbook-min` floor, or give the test a per-template floor. The
`runbook.md` / `runbook.min.md` fixtures and README rows did land —
`min + 15 < full` would pass today (8.8 + 15 < 83.8).

## Follow-ups filed

- #241 (agent:advanced, milestone 6) — runbook min render vs the
  `generic < min` invariant.
