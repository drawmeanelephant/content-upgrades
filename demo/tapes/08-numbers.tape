# Beat 8: the numbers card, measured only. This tape is the provenance
# shot: the commands that produce every number on the card, ending with
# demo/card/build.sh writing numbers.json + numbers.png. The card itself
# is a still placed in Kdenlive.
# target: 10s
# status: ready (card: I4; live takes: I2/I3 frozen under eval/results/live/)
# depends: knap-mcp eval (E1 corpora), eval/conformance/results (K3),
#   eval/results/live (I2 repair runs, I3 ratchet runs), demo/card/build.sh
Output demo/out/tapes/08-numbers.mp4
Require jq
Source demo/tapes/_settings.tape

Hide
Type "source demo/lib/env.sh && mkdir n && cd n && ln -s ../eval/results/live/acp-seeds.out s22.out && ln -s ../eval/results/live/acp-seeds.2nap.out s2.out && ln -s ../eval/results/live/devin-wonder/repair-seeds.out w22.out && ln -s ../eval/results/live/devin-wonder/repair-seeds.2nap.out w2.out && cd .. && ln -s $DEMO_ROOT/demo/card card"
Enter
Sleep 400ms
Show

# The hidden preamble makes short names for the I2 repair .out files
# (n/*.out) and links demo/card (card/), so every on-screen line fits the
# 121-column frame.

# The I2 repair runs: acp summarizer + Muse Wonder 1.0 via ACP (devin),
# both corpora. The card's mock control row is a fresh eval inside
# card/build.sh.
Type "grep '^converged' n/s22.out n/w22.out n/s2.out n/w2.out"
Enter
Sleep 1s

# Every number on the card, with its source: live runs, the mock eval,
# ratchet tallies, conformance, LOC; then the PNG render.
Type "card/build.sh"
Enter
Sleep 5s

# The three measured columns on the card.
Type "jq -r '.columns[].label' card/numbers.json"
Enter
Sleep 1s
