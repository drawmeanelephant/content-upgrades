# Beat 7: one source -> several document views. Same data, separate
# artifacts, native binaries only. Zero JavaScript.
# target: 15s
# status: ready
# depends: k4o (markdown, oliver), dogbed (html)
#
# Targets are markdown, oliver and html only: the k4o main pin has no
# textile or gfm output. oliver renders byte-identical to markdown for
# this template; html is what makes "several views" visible.
Output demo/out/tapes/07-one-source.mp4
Require jq
Source demo/tapes/_settings.tape
Set TypingSpeed 15ms

# v and a are copies of the sample data made in the hidden preamble to
# keep the typed lines under the 121-column frame.
Hide
Type "source demo/lib/env.sh && cp data/verdict.sample.json v && cp data/apparatus.sample.json a"
Enter
Sleep 300ms
Show

# One typed line renders all three verdict views (md/oliver/html); jq to
# {ok} keeps output to one short line each.
Type "for t in markdown oliver html; do knap-mcp render verdict -d v --target $t --out verdict.$t | jq -c '{ok}'; done"
Enter
Sleep 2.5s

Type "knap-mcp render apparatus -d a --target html --out apparatus.html | jq -c '{ok}'"
Enter
Sleep 1.5s

# The mv gives the markdown render its SPEC name; grep exits 1 (zero
# matches) so every file prints :0 -- zero JavaScript in any view.
Type "mv verdict.markdown verdict.md; grep -c '<script' verdict.md verdict.oliver verdict.html apparatus.html"
Enter
Sleep 6.5s

# TODO(T2/I5): SPEC wants one data.json behind both views; today the
#   apparatus template keeps its own sample file (it renders without
#   subtitle or quotes from verdict.sample.json).
