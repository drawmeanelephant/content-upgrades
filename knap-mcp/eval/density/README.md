# Density calibration fixtures

Markdown docs that pin the ordering of `src/density.zig`. The unit tests in
that file load them and assert `flat-barf < generic < verdict < dense-ideal`,
`flat-barf < apparatus`, `confetti < verdict`, that the pipe-table and
HTML-table renders of the pre-T2 verdict score within 2 points of each
other, and
that each T1 template's required-fields-only render (`*.min.md`, the
ratchet's starting line) scores above `generic` and at least 15 points
below its full sample.

| File | Class | Provenance |
|---|---|---|
| `flat-barf.md` | flat AI barf | Hand-written: title, wall paragraph, `## Conclusion`, wall paragraph |
| `generic.md` | clean but generic | Hand-written: headings, bold-lead bullet lists, no apparatus |
| `apparatus.md` | rendered template | `knap-mcp render apparatus -d data/apparatus.sample.json --target markdown` |
| `verdict.md` | rendered template | `knap-mcp render verdict -d data/verdict.sample.json --target markdown` (T2's verdict, pipe table) |
| `verdict-v1.pipe-table.md` | rendered template, frozen | The pre-T2 verdict template and sample, k4o `bdfb838` (pipe table). Do not re-render |
| `verdict-v1.html-table.md` | rendered template, frozen | The same pre-T2 doc from k4o `f97c5db`, whose `markdown` target emitted an HTML `<table>`. With the pipe-table twin it pins that both table forms score alike. Do not re-render |
| `release-notes.md` / `reading-note.md` | rendered template | `knap-mcp render <t> -d data/<t>.sample.json --target markdown` |
| `release-notes.min.md` / `reading-note.min.md` | rendered template, required fields only | `knap-mcp render <t> -d data/<t>.min.json --target markdown` |
| `confetti.md` | over-formatted | Hand-written: stacked callouts, bold on everything, emoji headings |
| `dense-ideal.md` | dense ideal | Hand-written: the verdict content with full apparatus (callouts, resolved footnotes, pipe table, wikilinks, deep links, embed, pull quote) |

The rendered fixtures came from k4o `bdfb838` (the main-line pin in
`scripts/engines.sh`); the two `verdict-v1.*` files are frozen (see above). The
old `verdict.gfm.md` is gone with the gfm target. Re-render them when the
templates or the engine pin change, then re-run the table:

```sh
cd knap-mcp
zig run -OReleaseFast --dep density -Mroot=eval/density/table.zig \
    -Mdensity=src/density.zig -- eval/density/*.md
```

Add `--json` before the file list for each doc's full signal breakdown.
