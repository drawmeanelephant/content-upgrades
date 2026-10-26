# Beat 8: the numbers, measured only. This tape records where each number
# comes from; the on-screen card itself is a still built by I4.
# target: 10s
# status: partial (mock eval, conformance lineage, LOC ready; real-backend table needs M1/I2; card needs I4)
# depends: knap-mcp eval (E1 corpora), eval/conformance/results (K3)
Output demo/out/tapes/08-numbers.mp4
Require jq
Source demo/tapes/_settings.tape

Hide
Type "source demo/lib/env.sh"
Enter
Sleep 300ms
Show

# The bigger corpus (E1, 185 breaks from 2nap). eval/seeds.json (the demo
# templates, 22 breaks) is the alternative if the card quotes that one.
Type "knap-mcp eval --corpus eval/seeds.2nap.json --backend mock | grep '^converged'"
Enter
Sleep 2.5s
# K3: quote the same-lineage line (base -> #70 -> #71), never main -> #70 -> #71.
Type "jq -r .headline eval/conformance/results/summary-lineage.json"
Enter
Sleep 1.5s
Type "cat $(find src/ -name '*.zig') | wc -l"
Enter
Sleep 1.5s

# TODO(M1/I2): the slide numbers are the real-backend runs, not mock:
#   Type "knap-mcp eval --corpus eval/seeds.2nap.json --backend spark | grep '^converged'"
# TODO(K2/K3): if the k4o pin moves, rerun eval/conformance/run.sh and
#   requote the headline.
# TODO: "calls x mean slice size" has no instrumentation yet; leave it off
#   the card until something measures it. No token-cost numbers.
