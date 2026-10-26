# Beat 8: the numbers, measured only. This tape records where each number
# comes from; the on-screen card itself is a still built by I4.
# target: 10s
# status: partial (mock eval, conformance totals, LOC ready; real-backend table needs M1/I2; card needs I4)
# depends: knap-mcp eval (E1 corpora), eval/conformance/results (K3)
Output demo/out/tapes/08-numbers.mp4
Require jq
Source demo/tapes/_settings.tape

Hide
Type "source demo/lib/env.sh"
Enter
Sleep 300ms
Show

# The bigger corpus (E1's 2nap breaks). eval/seeds.json (the demo templates)
# is the alternative if the card quotes that one. stderr carries one line
# per no-op or unrenderable seed under the pinned k4o; the summary counts them.
Type "knap-mcp eval --corpus eval/seeds.2nap.json --backend mock 2>/dev/null | grep '^converged'"
Enter
Sleep 2.5s
# K3's conformance result for the pinned engine (k4o main bdfb838). Never
# quote main -> #70 -> #71 as a progression (K3).
Type "jq -c '{label, totals}' eval/conformance/results/k4o-main-bdfb838.json"
Enter
Sleep 1.5s
Type "cat $(find src/ -name '*.zig') | wc -l"
Enter
Sleep 1.5s

# TODO(M1/I2): the slide numbers are the real-backend runs, not mock:
#   Type "knap-mcp eval --corpus eval/seeds.2nap.json --backend spark | grep '^converged'"
# TODO(K3): if the k4o pin moves again, point this at that revision's
#   results file (eval/conformance/run.sh writes one per pinned revision).
# TODO: "calls x mean slice size" has no instrumentation yet; leave it off
#   the card until something measures it. No token-cost numbers.
