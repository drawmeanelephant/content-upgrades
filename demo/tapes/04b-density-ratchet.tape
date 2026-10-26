# Beat 4b (optional, proposed): the density ratchet from the README pitch.
# SPEC's 8 beats predate it; whether it gets a slot is the captain's call.
# target: 15s
# status: placeholder (blocked on D1 scorer + D2 ratchet loop)
# depends: D1 (src/density.zig), D2 (knap_density, knap_ratchet)
Output demo/out/tapes/04b-density-ratchet.mp4
Require jq
Source demo/tapes/_settings.tape

Hide
Type "source demo/lib/env.sh"
Enter
Type `demo_slate 4b "density ratchet" "blocked on D1 + D2" "values-only loop: score climbs, drops revert, bounded 4-8 iterations"`
Enter
Sleep 300ms
Show
Sleep 15s

# Intended commands (names are proposals; match what D1/D2 ship):
#   Type "knap-mcp density fixtures/generic-ai-doc.md | jq '{total}'"
#   Enter
#   Sleep 2s
#   Type "knap-mcp ratchet apparatus -d data/apparatus.sample.json --backend mock | jq -c '.iterations[] | {i, score, kept}'"
#   Enter
#   Sleep 5s
#   Type "knap-mcp density ratcheted.md | jq '{total}'"
#   Enter
#   Sleep 2s
