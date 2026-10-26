# Beat 7: one source -> several document views. Same data, separate
# artifacts, native binaries only. Zero JavaScript.
# target: 15s
# status: partial (md + html ready; one shared data file needs T2/I5)
# depends: k4o (markdown), dogbed (html)
#
# Targets are markdown and html only: the k4o main pin has no textile or
# gfm output, and lane P1 narrows targets to markdown | oliver | html.
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
Type "knap-mcp render verdict -d data/verdict.sample.json --target html --out verdict.html | jq -c '{ok, bytes}'"
Enter
Sleep 1s
Type "knap-mcp render apparatus -d data/apparatus.sample.json --target html --out apparatus.html | jq -c '{ok, bytes}'"
Enter
Sleep 1s
Type "grep -c '<script' verdict.md verdict.html apparatus.html"
Enter
Sleep 3s

# TODO(P1): add the oliver target here once P1 ships it.
# TODO(T2/I5): SPEC wants one data.json behind both views; today the
#   apparatus template needs its own sample file (it renders without
#   subtitle or quotes from verdict.sample.json).
