# Beat 5: the boris catch. A hallucinated wikilink renders fine, then fails
# the publish check against the frozen boris site: references caught
# before publish, made visible.
# target: 15s
# status: ready (knap_publish_check, B2)
# depends: B1 (boris-site/, boris on PATH), B2 (knap_publish_check) — shipped
#
# bad.json / good.json are copies made in the hidden preamble so the typed
# lines stay short: bad.json is the sample data plus one invented source,
# "AcmeDB SOC 2 audit report", which has no page in the frozen site
# (demo_seed_hallucinated_source in demo/lib/env.sh, the same line
# boris-site/selftest.sh injects); good.json is data/verdict.sample.json.
Output demo/out/tapes/05-boris-catch.mp4
Require boris
Require jq
Source demo/tapes/_settings.tape

Hide
Type "source demo/lib/env.sh && demo_seed_hallucinated_source && cp seeded/verdict.hallucinated.json bad.json && cp data/verdict.sample.json good.json"
Enter
Sleep 300ms
Show

# The template renders it without complaint: layout can't know a source is invented.
Type "knap-mcp render verdict -d bad.json | tee v1.json | jq -c '{ok,bytes}'"
Enter
Sleep 1.2s

# knap_publish_check stages the rendered doc into a copy of the frozen site
# and runs boris validate: the invented wikilink has no target (exit 1).
Type "knap-mcp publish-check $(jq -r .doc_id v1.json) | jq -c '.diagnostics[]'"
Enter
Sleep 3.5s

# The real sources resolve: same check, ok, exit 0.
Type "v2=$(knap-mcp render verdict -d good.json | jq -r .doc_id)"
Enter
Sleep 700ms
Type "knap-mcp publish-check $v2 | jq -c '{ok,links,pages}'"
Enter
Sleep 3s
