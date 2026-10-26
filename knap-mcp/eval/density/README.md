# Density calibration fixtures

Markdown docs that pin the ordering of `src/density.zig`. The unit tests in
that file load them and assert `flat-barf < generic < verdict < cunty`,
`flat-barf < apparatus`, `confetti < verdict`, and that the markdown and gfm
renders of the verdict score within 2 points of each other.

| File | Class | Provenance |
|---|---|---|
| `flat-barf.md` | flat AI barf | Hand-written: title, wall paragraph, `## Conclusion`, wall paragraph |
| `generic.md` | clean but generic | Hand-written: headings, bold-lead bullet lists, no apparatus |
| `apparatus.md` | rendered template | `knap-mcp render apparatus -d data/apparatus.sample.json --target markdown` |
| `verdict.md` | rendered template | `knap-mcp render verdict -d data/verdict.sample.json --target markdown` (HTML `<table>`) |
| `verdict.gfm.md` | rendered template | Same, `--target gfm` (pipe table) |
| `confetti.md` | over-formatted | Hand-written: stacked callouts, bold on everything, emoji headings |
| `cunty.md` | dense ideal | Hand-written: the verdict content with full apparatus (callouts, resolved footnotes, pipe table, wikilinks, deep links, embed, pull quote) |

The rendered fixtures came from k4o `f97c5db` (`~/.cache/knap-engines/k4o-f97c5db`).
Re-render them when the templates or the engine pin change, then re-run the
table:

```sh
cd knap-mcp
zig run -OReleaseFast --dep density -Mroot=eval/density/table.zig \
    -Mdensity=src/density.zig -- eval/density/*.md
```

Add `--json` before the file list for each doc's full signal breakdown.
