# Beat 7: one source -> several document views. Same data, separate
# artifacts, native binaries only. Zero JavaScript.
# target: 15s
# status: partial (md + textile ready; html needs K2; one shared data file needs T2/I5)
# depends: k4o (markdown, textile), dogbed (html, after K2)
Output demo/out/tapes/07-one-source.mp4
Require jq
Source demo/tapes/_settings.tape

Hide
Type "source demo/lib/env.sh"
Enter
Sleep 300ms
Show

Type "knap-mcp render verdict -d data/verdict.sample.json --target markdown --out verdict.md | jq -c '{ok, bytes}'"
Enter
Sleep 1s
Type "knap-mcp render verdict -d data/verdict.sample.json --target textile --out verdict.textile | jq -c '{ok, bytes}'"
Enter
Sleep 1s
Type "knap-mcp render apparatus -d data/apparatus.sample.json --target markdown --out apparatus.md | jq -c '{ok, bytes}'"
Enter
Sleep 1s
Type "grep -c '<script' verdict.md verdict.textile apparatus.md"
Enter
Sleep 3s

# TODO(K2): the pinned dogbed bundles a pre-#70 k4o, so html fails on
#   `yaml` (verdict) and `wikilink` (apparatus). After the bump, add:
#   Type "knap-mcp render apparatus -d data/apparatus.sample.json --target html --out apparatus.html | jq -c '{ok, bytes}'"
#   and include apparatus.html in the grep.
# TODO(T2/I5): SPEC wants one data.json behind both views; today the
#   apparatus template needs its own sample file (it renders without
#   subtitle or quotes from verdict.sample.json).
