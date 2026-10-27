# Track ADOC: audit docs pass — stale claims, verdict min/full data, SPEC drift

Status: done. Lane files: `demo/storyboard.md`, this note,
`docs/tracks/V0.md`, `knap-mcp/data/verdict.min.json`,
`knap-mcp/data/verdict.full.json`. Nothing else touched.

Closes audit issue #53. Everything below was verified on `origin/main` at
0038082 (pins k4o `aeba163`, dogbed `188ccac`), Oct 26.

## What changed

- `demo/storyboard.md`
  - Beat 2: dropped the stale warning that `initialize` returns invalid
    JSON. Verified over stdio: `initialize`, `tools/list`, `tools/call`
    and error responses all parse. Also corrected "the six tool names" —
    `tools/list` returns 14 tools today.
  - Beat 4: replaced the "Visual bugs to fix before the final take" list
    with the verified state: real `| Claim | Evidence | Source |` header
    row, in-text `[^benchmark]`/`[^backup-gap]` refs, `format-check`
    returns zero warnings on the sample render.
  - Beat 1: the density overlay is unblocked — `knap-mcp density <file>`
    scores the fixture directly (3.7 on density/1).
  - Beat 4b: `verdict.min.json` ships now; noted that the tape still runs
    the README's `release-notes` example and that verdict's shape carries
    no ratchet slots yet.
  - Beat 7: "one shared data file" marked cut (T2/I5 deferred); apparatus
    keeps `data/apparatus.sample.json`. The "Changed from SPEC" note now
    says SPEC names `verdict.oliver` — the tape shows verdict.html because
    oliver renders byte-identical to markdown for this template.
  - Engine pins refreshed to `aeba163`/`188ccac`; the "repaired doc is
    byte-identical" claim re-verified on `aeba163` (real
    `demo_seed_unclosed_if` seed, `diff` clean).
  - Beat 8's conformance number was already 187/188 on main; confirmed
    against `eval/conformance/results/k4o-main-aeba163.*`.
- `docs/tracks/V0.md`: the "Bugs found" list is annotated item by item —
    1–3, 5, 8, 11, 12 resolved (re-verified, notes inline), 9 marked
    deferred/cut with beat 7, 6/7/10 still open. Beat-status bullets in
    "What landed" updated to current storyboard state.
- `knap-mcp/data/verdict.min.json` (new): required fields only
  (`title`, `verdict`, `take`, `summary`, `bottom_line`) plus a `sources`
  array in the verdict shape — each entry also carries a `quote`, so it
  doubles as the ratchet evidence pool (`data.sources[*].quote`, same role
  the other `.min.json` files' `sources` play, but in the verdict shape so
  the Sources section still renders cleanly).
- `knap-mcp/data/verdict.full.json` (new): every slot filled — like
  `verdict.sample.json` plus a `note`/`region-gap` footnote on the third
  receipt and a third real site source ("AcmeDB issue #412 — cross-region
  replication").

## SPEC drift — recommended edits (captain-owned files, not touched)

Verified against the shipped implementation on main:

1. **`knap_publish_check` signature** — `docs/SPEC.md` "Tool surface"
   (~line 134) says `knap_publish_check(doc_id, site)`. The shipped tool
   takes `doc_id` only (`tools/publish_check.zig` input_schema:
   `{"doc_id"}` required); the site is the frozen boris site the server
   already knows. Suggested: `knap_publish_check(doc_id)` and keep the
   rest of the sentence — the description's "the frozen boris site"
   already explains where it stages.
2. **`knap_format_check` rule count** — `docs/SPEC.md` (~line 145) says
   "~8 pinned rules" and names eight. `src/formatcheck.zig` ships nine;
   `knap-mcp/README.md` says 9. The ninth is `unused-footnote` (footnote
   defined, never referenced — distinct from `unresolved-footnote`).
   Suggested: "9 pinned rules" and add unused footnotes to the named list.
3. **`knap_templates` catalog** — `docs/SPEC.md` (~line 123) says "Slim
   catalog by default; shape fetched per-template on request." The
   implementation inlines each template's `shape` in the catalog response
   (`tools/templates.zig` comment acknowledges the deviation). Suggested:
   SPEC says the catalog returns `shape` inline per template — or mark it
   an accepted deviation.
4. **Demo beat 7 target** — `docs/SPEC.md` (~line 225) says "verdict.md +
   apparatus.html + verdict.oliver". The textile reference is already
   gone; the residual drift is oliver vs html. The tape renders
   verdict.html because oliver output is byte-identical to markdown for
   this template (verified), so a third "view" needs html to be visible.
   Suggested: "verdict.md + verdict.html + apparatus.html" — or keep
   oliver in SPEC and accept the tape deviation.

## Stale items found outside this lane's ownership

- `demo/tapes/08-numbers.tape` line ~24 types
  `jq -c '{label, totals}' eval/conformance/results/k4o-main-bdfb838.json`
  — that file does not exist on main (`k4o-main-aeba163.json` does). The
  typed command would print a jq error on screen. Needs the path fixed or
  a retake. Line ~22 comment also names `bdfb838`.
- `demo/tapes/04-the-doc.tape` line ~30 comment references dogbed
  `d7ffaba`; the pin is `188ccac`.
- `docs/GAMEPLAN.md` line ~87 says "`knap_render` (md/html/textile
  targets)" — textile is dropped. Captain-owned.
- `docs/tracks/CAPTAIN.md` ~line 25 still logs the storyboard's "181/188"
  as deferred-until-I1; it is resolved (storyboard says 187/188).
  Informational only.
- `docs/tracks/V0.md` "## Gate output" still quotes the Oct 26 run on
  c74696d with the old pins — left as a labeled historical record.

## Gate output

```text
$ make test
cd knap-mcp && zig build test            # exit 0

$ KNAP_MCP_HOME=$(mktemp -d) make eval
converged 12/22 breaks   mean iters 1.25   exact 4/12   no-op seeds 0   controls 3/3 clean
converged 120/167 breaks   mean iters 1.19   exact 58/115   no-op seeds 0   controls 2/2 clean

$ knap-mcp render verdict -d data/verdict.min.json --target markdown|oliver|html
ok:true, 0 diagnostics (all three targets; html via dogbed 188ccac)
$ knap-mcp render verdict -d data/verdict.full.json --target markdown|oliver|html
ok:true, 0 diagnostics (all three targets)
$ knap-mcp format-check <full render>      # zero warnings
$ knap-mcp ratchet verdict -d data/verdict.min.json --backend mock
{"ok":true,"stop":"ceiling","slot_fill":{"start":"0/0","final":"0/0"}}
# 0/0: verdict's shape has no `apparatus`-annotated slots yet (§2.3 shape
# work). The run is clean — no schema errors, exit 0.

$ make demo                               # all beats run on mock backend
```
