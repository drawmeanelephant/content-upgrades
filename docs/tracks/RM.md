# RM: roadmap moved to GitHub milestones

On Oct 26 the remaining items from `docs/GAMEPLAN.md`, `docs/PARALLEL-PLAN.md`,
`docs/next-phase-plan.md`, `docs/tracks/CAPTAIN.md` and the open follow-ups in
`docs/tracks/*.md` became GitHub milestones and issues. Each item was checked on
`main` (`2051311`) before it was filed. The milestones are now the source of
truth; the plan docs are history.

| Milestone | Due (ET) | Issues |
|---|---|---|
| 1 · Pre-freeze hardening | Oct 29 EOD | #60–#63 (scorer batch, in order #61 → #63 → #62 → #60), #74–#84 |
| 2 · Live models + freeze | Oct 30 EOD (freeze) | #85–#93 |
| 3 · Demo video | Nov 2 EOD | #94–#103 |
| 4 · Ship | Nov 4 noon | #104–#106 |

Labels: `agent:swe-2` (default), `agent:advanced` (Opus-class; the body says
why), `human-only`, `blocked:model-key`, `stretch`.

## Plan lane → issue

| Lane / item | Issue |
|---|---|
| M1 live backends | #89 (needs #85) |
| I2 convergence table | #90 |
| I3 density model matrix | #91 (after #60 freezes density/2) |
| I4 numbers card | #101 |
| I5 freeze | #93 |
| Wave 3 tapes, one per beat | #94–#101 (beat 5 is ready; no issue) |
| CI `make demo` (PR #66 failing) | #74 |
| V0 bug 6 (mock unknown-filter) | #78 |
| V0 bug 7 (patch not visible) | #77 |
| D2 follow-ups: fragment_link, verdict slots, ε filter, block separation, footnote step, boris evidence | #75, #76, #79, #81, #83, #82 |
| SPEC beat 8 calls × slice size | #80 |
| GAMEPLAN Phase 1 human items | #85, #86, #87, #88 |
| Video assembly, art, submission | #102, #103, #106 |

## Checked and not filed (already fixed on main)

- CAPTAIN trailing-`!` footnote hazard: the voice guard has
  `footnote_abutting` (`src/voice.zig`).
- CAPTAIN dogbed findings (verdict html drops footnote definitions;
  frontmatter shows as text): fixed. The verdict html has `#fn-N` refs and no
  frontmatter leak (#42, pin `d96b125`).
- "One shared data file" (V0 bug 9): still cut, not filed.
