# Beat 1: cold open, the generic AI doc. Clean, but flat: no callouts,
# no footnotes, no deep links, voice ironed out.
# target: 5s
# status: ready (fixture doc); density score blocked on D1
# depends: demo/fixtures/generic-ai-doc.md
#
# No typing on screen: the doc is already up when the clip starts.
Output demo/out/tapes/01-cold-open.mp4
Require glow
Require jq
Source demo/tapes/_settings.tape

Hide
Type "source demo/lib/env.sh"
Enter
Type "clear; glow fixtures/generic-ai-doc.md"
Enter
Sleep 1s
Show
Sleep 5s

# TODO(D1): show the flat doc's density score (expected: low).
#   Type "knap-mcp density fixtures/generic-ai-doc.md | jq '{total}'"
#   Enter
#   Sleep 2s
