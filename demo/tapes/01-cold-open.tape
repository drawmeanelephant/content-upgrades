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
#   docs/next-phase-plan.md has `knap-mcp density <doc_id>`, which scores
#   stored docs only, so this fixture can't be scored from the CLI. Either
#   D1 accepts a file path, or the cold open switches to the plan's
#   "generic" artifact (a template rendered with only required fields):
#   Type "knap-mcp density $(knap-mcp render verdict -d seeded/verdict.required.json | jq -r .doc_id) | jq -c '{score}'"
#   Enter
#   Sleep 2s
