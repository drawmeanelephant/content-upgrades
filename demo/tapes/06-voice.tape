# Beat 6: same template x mild vs feral. Same line count, and only the
# voiced lines differ: voice rewrites values and cannot touch layout.
# target: 20s
# status: partial (C3 mock replies stand in for knap_voice; structure hash needs C2)
# depends: C3 (prompts/voice/mock/*.jsonl), C1 (knap_voice), C2 (structure hash)
#
# seeded/verdict.<tone>.json is derived at take time: the sample data with
# C3's canned mock replies applied (demo_seed_voice in demo/lib/env.sh).
# That is GAMEPLAN's fallback (hand-authored mild/feral data) and what
# knap_voice's mock backend should return.
Output demo/out/tapes/06-voice.mp4
Require jq
Source demo/tapes/_settings.tape

Hide
Type "source demo/lib/env.sh && demo_seed_voice mild feral"
Enter
Sleep 300ms
Show

Type "for t in mild feral; do knap-mcp render verdict -d seeded/verdict.$t.json --out $t.md | jq -c '{ok, bytes}'; done"
Enter
Sleep 1.5s

Type "wc -l mild.md feral.md"
Enter
Sleep 2s

# Four lines differ: heading, verdict + take, summary, bottom line.
Type "diff mild.md feral.md"
Enter
Sleep 10s

# TODO(C1): replace demo_seed_voice with the real voice pass. Proposed:
#   Type "knap-mcp voice verdict -d data/verdict.sample.json --tone feral --backend mock | cat > seeded/verdict.feral.json"
# TODO(C2): put the structure hash on screen before the diff; equal hashes
#   are the falsifiable proof, line counts are only a hint. Proposed:
#   Type "knap-mcp structhash mild.md feral.md"
# Note: `> file` redirects of knap-mcp stdout overwrite from offset 0
# (see docs/tracks/V0.md); pipe through cat until that is fixed.
