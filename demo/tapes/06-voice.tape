# Beat 6: same template x mild vs feral. Same structure hash and line count,
# and only the voiced lines differ: voice rewrites values and cannot touch
# layout.
# target: 20s
# status: ready (knap_voice C1 + knap_structhash C2, mock backend)
# depends: C3 (prompts/voice/mock/*.jsonl), C1 (knap_voice), C2 (structure hash) — shipped
#
# knap_voice with --backend mock returns C3's canned replies, so the take is
# fixed. v0.json is a copy of data/verdict.sample.json made in the hidden
# preamble to keep the typed lines under the frame width. voice.<tone>.json
# holds the full tool result; jq .data extracts the rewritten template data.
Output demo/out/tapes/06-voice.mp4
Require jq
Source demo/tapes/_settings.tape

Hide
Type "source demo/lib/env.sh && cp data/verdict.sample.json v0.json"
Enter
Sleep 300ms
Show

# The real voice pass, one line per tone pair: rewrites only the voice:true
# values. KNAP_BACKEND=mock comes from env.sh, so --backend stays off screen
# here (frame width); the mock returns the canned replies demo_seed_voice
# used to apply.
Type "for t in mild feral; do knap-mcp voice verdict -d v0.json --tone $t | tee $t.json | jq -c '{tone,changed}'; done"
Enter
Sleep 2.5s

# jq .data unwraps the tool result into the template data render expects.
Type "for t in mild feral; do jq .data $t.json | knap-mcp render verdict -d - --out $t.md | jq -c '{ok,bytes}'; done"
Enter
Sleep 1.8s

# The falsifiable proof: identical layout skeletons and line counts (69 each),
# so only values changed. wc stays off screen; the hash is the stronger claim.
Type "knap-mcp structhash mild.md feral.md"
Enter
Sleep 3s

# Six lines differ: title + verdict in frontmatter and body, the summary,
# and the bottom line. Everything else (table, sources, footnotes) is identical.
Type "diff mild.md feral.md"
Enter
Sleep 5.5s

# TODO(M1): swap --backend mock for a live backend once MODEL_API_KEY lands.
