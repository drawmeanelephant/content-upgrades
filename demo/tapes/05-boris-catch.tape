# Beat 5: the boris catch. A hallucinated wikilink renders fine, then fails
# the publish check against the frozen boris site: references caught
# before publish, made visible.
# target: 15s
# status: partial (B1's stage-check.sh stands in for knap_publish_check until B2)
# depends: B1 (boris-site/, stage-check.sh, boris on PATH), B2 (knap_publish_check)
#
# seeded/verdict.hallucinated.json is derived at take time: the sample data
# plus one invented source, "AcmeDB SOC 2 audit report", which has no page
# in the frozen site (demo_seed_hallucinated_source in demo/lib/env.sh, the
# same line boris-site/selftest.sh injects).
Output demo/out/tapes/05-boris-catch.mp4
Require boris
Require jq
Source demo/tapes/_settings.tape

Hide
Type "source demo/lib/env.sh && demo_seed_hallucinated_source"
Enter
Sleep 300ms
Show

# The template renders it without complaint: layout can't know a source is invented.
Type "knap-mcp render verdict -d seeded/verdict.hallucinated.json --out v1.md | jq -c '{ok, bytes}'"
Enter
Sleep 1s

# Staged into a throwaway copy of the frozen site: the wikilink has no target.
Type "boris-site/stage-check.sh v1.md"
Enter
Sleep 3.2s

# The real sources resolve. Short file names keep stage-check's ok line
# under the 121-column width.
Type "knap-mcp render verdict -d data/verdict.sample.json --out v2.md >/dev/null && boris-site/stage-check.sh v2.md"
Enter
Sleep 2.5s

# TODO(B2): swap stage-check.sh for the knap-mcp command once it ships
#   (docs/next-phase-plan.md: knap_publish_check runs `boris validate` for
#   references; boris has no --fail-on-unlinked). Proposed:
#   Type "knap-mcp publish-check $(knap-mcp render verdict -d seeded/verdict.hallucinated.json | jq -r .doc_id) | jq -c '.diagnostics[]'"
