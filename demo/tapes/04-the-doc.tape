# Beat 4: the doc. Real table, wikilinked sources, footnotes, frontmatter,
# sass intact, from the same fixed template.
# target: 30s
# status: partial (renders now; callouts need T2; art is a Kdenlive overlay)
# depends: knap-mcp render (k4o gfm target), glow
Output demo/out/tapes/04-the-doc.mp4
Require glow
Require jq
Source demo/tapes/_settings.tape

Hide
Type "source demo/lib/env.sh"
Enter
Sleep 300ms
Show

Type "knap-mcp render verdict -d data/verdict.sample.json --target gfm --out verdict.md | jq -c '{ok, target, bytes}'"
Enter
Sleep 1.5s

# The doc is about 1.5 pages; the clip ends inside the pager, on the doc.
Type "glow -p verdict.md"
Enter
Sleep 11s
Space
Sleep 13s

# TODO(T2): callouts (and set/??) in verdict/apparatus once the templates use them.
# TODO(K2): the hero shot is better as dogbed HTML in a browser (capture
#   with OBS or a headless screenshot); the pinned dogbed fails on html today.
# TODO(T2): knap-mcp format-check on this doc warns about 2 unused footnotes
#   and 2 bare URLs; fix the template before putting format-check on screen:
#   Type "knap-mcp format-check $(knap-mcp render verdict -d data/verdict.sample.json | jq -r .doc_id) | jq -c '.warnings[]'"
# TODO(D1): density score for this doc next to beat 1's (expected: high).
#   Type "knap-mcp density verdict.md | jq '{total}'"
