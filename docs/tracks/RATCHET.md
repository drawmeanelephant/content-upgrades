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
