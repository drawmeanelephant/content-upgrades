# Beat 5: the boris catch. A hallucinated wikilink fails
# knap_publish_check: references caught pre-publish, made visible.
# target: 15s
# status: placeholder (blocked on B1 frozen site + B2 publish_check)
# depends: B1 (boris-site/), B2 (knap_publish_check, data/*.hallucinated.json)
Output demo/out/tapes/05-boris-catch.mp4
Require jq
Source demo/tapes/_settings.tape

Hide
Type "source demo/lib/env.sh"
Enter
Type `demo_slate 5 "the boris catch" "blocked on B1 + B2" "a hallucinated [[wikilink]] fails knap_publish_check before publish"`
Enter
Sleep 300ms
Show
Sleep 15s

# Intended commands (names are proposals; match what B2 ships):
#   Type "knap-mcp render verdict -d data/verdict.hallucinated.json --out verdict.md | jq -c '{ok, doc_id}'"
#   Enter
#   Sleep 2s
#   Type "knap-mcp publish-check $(knap-mcp render verdict -d data/verdict.hallucinated.json | jq -r .doc_id) | jq"
#   Enter
#   Sleep 5s
#   Expected on screen: an unresolved [[wikilink]] target as a graph
#   diagnostic, non-zero exit. Then the fixed data passes.
