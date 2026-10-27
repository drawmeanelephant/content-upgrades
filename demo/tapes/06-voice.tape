# Beat 6: same template x mild vs feral, on the frozen live voice takes.
# Voice rewrites values only: three renders, one layout hash, and diff
# shows just the voiced lines.
# target: 20s
# status: ready (frozen live takes, I5)
# depends: demo/frozen/06-voice-{mild,feral}.json (I5), knap_structhash C2
#
# v.<tone>.json are the recorded knap_voice results: Muse Wonder 1.0 via
# ACP (devin, low thinking), one take each on 2026-10-27 (provenance in
# demo/frozen/provenance.json). Nothing on tape calls a live model;
# jq .data unwraps the rewritten template data and render runs offline.
# d.orig.json is the curated sample. structhash must print
# 6a738a8906ac2273 for all three renders (demo/frozen/06-structhash.txt);
# anything else means the frozen outputs don't hold — stop, don't retake.
Output demo/out/tapes/06-voice.mp4
Require jq
Source demo/tapes/_settings.tape

Hide
Type "source demo/lib/env.sh && cp data/verdict.sample.json d.orig.json"
Enter
Type "for t in mild feral; do cp $DEMO_ROOT/demo/frozen/06-voice-$t.json v.$t.json; done"
Enter
Type "for t in mild feral; do jq .data v.$t.json > d.$t.json; done && clear"
Enter
Sleep 300ms
Show

# The label goes on screen with the frozen tool results: 8 fields
# rewritten per tone, 0 rejected.
Type "echo '# voice: Muse Wonder 1.0 via ACP (devin, low thinking)'; jq -c '{tone,changed}' v.{mild,feral}.json"
Enter
Sleep 2s

# Offline renders: the curated sample plus both frozen takes.
Type "for t in orig mild feral; do knap-mcp render verdict -d d.$t.json --out $t.md | jq -c '{ok,bytes}'; done"
Enter
Sleep 1.8s

# The falsifiable proof: identical layout skeletons (70 lines each), so
# only values changed. One hash across all three renders.
Type "knap-mcp structhash orig.md mild.md feral.md"
Enter
Sleep 3s

# Six hunks differ: title + verdict in frontmatter and body, the summary,
# and the bottom line. fold wraps the long summary line inside the frame;
# everything else (table, sources, footnotes) is identical.
Type "diff mild.md feral.md | fold -s -w 118"
Enter
Sleep 3.4s
