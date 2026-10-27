# Beat 1: cold open, the frozen real flat doc. A verbatim model reply
# (gpt-5-5-none via ACP (devin), frozen in #140), clean but flat: no
# callouts, no footnotes, no deep links, no table, voice ironed out.
# target: 5s
# status: ready (frozen real take, labeled as model output on screen)
# depends: demo/fixtures/generic-ai-doc.md
#
# No typing on screen: the doc and its label are already up when the clip
# starts. The label is a dim caption row printed under the doc. The
# density/2 score (25.7) is recorded in the storyboard row for the
# Kdenlive overlay (human).
Output demo/out/tapes/01-cold-open.mp4
Require glow
Require jq
Source demo/tapes/_settings.tape

Hide
Type "source demo/lib/env.sh"
Enter
Type `clear; glow fixtures/generic-ai-doc.md; printf '\e[2m%s\e[0m\n' 'model output: gpt-5-5-none via ACP (devin)'`
Enter
Sleep 1s
Show
Sleep 5s
