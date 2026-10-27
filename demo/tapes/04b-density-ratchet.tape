# Beat 4b (optional, proposed): the density ratchet from the README pitch.
# SPEC's 8 beats predate it; whether it gets a slot is the captain's call.
# target: 15s
# status: ready (mock backend); live take: devin-wonder ACP profile
# depends: D1 (src/density.zig), D2 (knap_density, knap_ratchet) — shipped
#
# data/release-notes.min.json is the shipped required-fields-only data file
# (the README's ratchet example). data/verdict.min.json ships too — verdict
# ratchets 1/7 -> 3/7 on the mock backend — but release-notes is the README
# example, so it stays the generic doc here. r0.json is a copy made in the
# hidden preamble to keep the typed line under the frame width.
Output demo/out/tapes/04b-density-ratchet.mp4
Require jq
Source demo/tapes/_settings.tape

Hide
Type "source demo/lib/env.sh && cp data/release-notes.min.json r0.json"
Enter
Sleep 300ms
Show

# One call; the server probes each empty slot, asks the backend for a value,
# keeps only the fills that raise the density score. The generic start doc
# (required fields only) is score.start in the summary below.
Type "knap-mcp ratchet release-notes -d r0.json --backend mock | tee ratchet.json | jq -c '{ok,stop}'"
Enter
Sleep 1.5s

# Each accepted step: which slot filled and how much the score climbed.
Type "jq -c '.steps[] | {slot, gain, accepted}' ratchet.json"
Enter
Sleep 3.5s

# Start 39.2 -> final 82.5; the ceiling is the all-slots-filled probe score.
Type "jq -c '{score, slot_fill, stop}' ratchet.json"
Enter
Sleep 4s

# TODO: swap --backend mock for --backend acp with
# KNAP_ACP_AGENT='devin acp --model muse-wonder-1-0-low' (the devin-wonder
# profile in scripts/providers.sh) for a live take.
