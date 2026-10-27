# Beat 3: seeded template failure -> pinned diagnostic -> frozen live
# repair take with the patch visible -> clean doc. The break is
# pre-seeded (never rely on a live failure); the repair playback is the
# converging live take frozen by I5 (demo/frozen/03-repair.json,
# 03-repaired.md) — nothing on tape calls a live model.
# target: 25s
# status: ready (frozen live repair take, Muse Wonder 1.0 via ACP (devin))
# depends: k4o diagnostic for the unclosed-if seed, demo/frozen/03-*
#
# seeded/verdict.knap is derived at take time: the shipped verdict
# template minus its first `{% endif %}` line (demo_seed_unclosed_if in
# demo/lib/env.sh), the same class as the eval corpus's unclosed-if seed.
# repair.json / repaired.md are the frozen take copied to short names in
# the hidden preamble; RS is steps[0].region_start for the patch diff.
Output demo/out/tapes/03-repair.mp4
Require glow
Require jq
Source demo/tapes/_settings.tape

Hide
Type "source demo/lib/env.sh && demo_seed_unclosed_if verdict && cp $DEMO_ROOT/demo/frozen/03-repair.json repair.json && cp $DEMO_ROOT/demo/frozen/03-repaired.md repaired.md && RS=$(jq -r '.steps[0].region_start' repair.json)"
Enter
Sleep 300ms
Show

# The seeded break: one line gone from the shipped template.
Type "diff templates/verdict.knap seeded/verdict.knap"
Enter
Sleep 1.5s

# Pinned diagnostic from the engine (k4o): kind, line, column, detail.
Type "KNAP_TEMPLATES_DIR=seeded knap-mcp validate verdict -d data/verdict.sample.json | jq -c '.diagnostics[0]'"
Enter
Sleep 2s

# The frozen live repair take (I5), labeled with the model.
Type "echo '# frozen live take: Muse Wonder 1.0 via ACP (devin)'"
Enter
Sleep 600ms

Type "jq -c '{converged,iterations,step:.steps[0]|{line,detail}}' repair.json"
Enter
Sleep 1.5s

# The patch itself: steps[0].patch diffed against the seeded region it
# replaces — the missing {% endif %} comes back, folded onto the if line.
# jq -j keeps jq from appending a newline the model did not emit.
Type "diff <(tail -n +$RS seeded/verdict.knap) <(jq -j '.steps[0].patch' repair.json)"
Enter
Sleep 2.5s

# The frozen repaired doc. The clip ends inside the pager, on the doc.
Type "glow -p repaired.md"
Enter
Sleep 4.5s
