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

# Intended commands, using the CLI and output shapes proposed in
# docs/next-phase-plan.md (match whatever D1/D2 ship). The start is the
# plan's "generic" doc, a template with only required fields filled; the
# ratchet only fills empty slots, so the full sample data has little to gain.
#   Type "knap-mcp ratchet verdict -d seeded/verdict.required.json --backend mock | tee ratchet.json | jq -c '.steps[] | {iteration, slot, gain, accepted, reason}'"
#   Enter
#   Sleep 5s
#   Type "jq -c '{score, slot_fill, stop}' ratchet.json"
#   Enter
#   Sleep 3s
