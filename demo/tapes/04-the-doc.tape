# Beat 4: the doc. Callouts, real table, wikilinked sources, footnotes,
# frontmatter, sass intact, from the same fixed template.
# target: 30s
# status: ready (art is a Kdenlive overlay; hero still: demo/hero/verdict.png)
# depends: knap-mcp render (k4o markdown target), glow
Output demo/out/tapes/04-the-doc.mp4
Require glow
Require jq
Source demo/tapes/_settings.tape

Hide
Type "source demo/lib/env.sh"
Enter
Sleep 300ms
Show

Type "knap-mcp render verdict -d data/verdict.sample.json --target markdown --out verdict.md | jq -c '{ok, target, bytes}'"
Enter
Sleep 1.5s

# The doc is about 1.5 pages; the clip ends inside the pager, on the doc.
Type "glow -p verdict.md"
Enter
Sleep 11s
Space
Sleep 13s

# The hero shot is the styled dogbed html still, demo/hero/verdict.png
# (demo/hero/build.sh: wrap + headless Chrome, zero JavaScript); it is
# composited in Kdenlive, not on this tape. The Muse Image art overlay is
# human work and goes in the still's empty right third.
# Off screen (the 30s budget goes to the doc itself; demo/run.sh beat 4
# shows them): format-check (zero warnings on this render) and density
# (density/2 77.4, next to beat 1's 25.7).
