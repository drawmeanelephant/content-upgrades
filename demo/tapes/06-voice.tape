# Beat 6: same template x mild vs feral. Structure hashes equal, strings
# differ: the falsifiable proof that voice cannot touch layout.
# target: 20s
# status: placeholder (blocked on C1 voice + C2 structure hash + C3 presets)
# depends: C1 (knap_voice), C2 (structhash / voice-eval), C3 (prompts/voice/*.md)
Output demo/out/tapes/06-voice.mp4
Require jq
Source demo/tapes/_settings.tape

Hide
Type "source demo/lib/env.sh"
Enter
Type `demo_slate 6 "same template, two voices" "blocked on C1 + C2 + C3" "mild vs feral: structure hashes equal, strings differ"`
Enter
Sleep 300ms
Show
Sleep 20s

# Intended commands (names are proposals; match what C1/C2 ship):
#   Type "knap-mcp voice verdict -d data/verdict.sample.json --tone mild --backend mock > mild.json"
#   Enter
#   Type "knap-mcp voice verdict -d data/verdict.sample.json --tone feral --backend mock > feral.json"
#   Enter
#   Type "knap-mcp render verdict -d mild.json --out mild.md >/dev/null; knap-mcp render verdict -d feral.json --out feral.md >/dev/null"
#   Enter
#   Type "knap-mcp structhash mild.md feral.md"
#   Enter
#   Sleep 3s
#   Type "diff mild.md feral.md | head -12"
#   Enter
#   Sleep 5s
# Note: `> file` redirects of knap-mcp stdout currently overwrite from
# offset 0 (see docs/tracks/V0.md); pipe through cat until that is fixed.
