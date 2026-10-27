# Beat 4b (optional, proposed): the density ratchet from the README pitch.
# SPEC's 8 beats predate it; whether it gets a slot is the captain's call.
# target: 15s
# status: ready (mock backend); a live ratchet run needs M1
# depends: D1 (src/density.zig), D2 (knap_density, knap_ratchet) — shipped
#
# data/release-notes.min.json is the shipped required-fields-only data file
# (the README's ratchet example). verdict has no .min.json, so the generic
# doc here is release-notes, not verdict as the plan proposed. r0.json is a
# copy made in the hidden preamble to keep the typed line under the frame width.
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

# Start 44.5 -> final 71.3; the ceiling is the all-slots-filled probe score.
Type "jq -c '{score, slot_fill, stop}' ratchet.json"
Enter
Sleep 4s

# TODO(M1): swap --backend mock for a live backend once MODEL_API_KEY lands.
