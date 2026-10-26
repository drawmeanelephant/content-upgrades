# Beat 3: seeded template failure -> pinned diagnostic -> bounded repair
# loop -> clean. The break is pre-seeded (never rely on a live failure).
# target: 25s
# status: ready (mock backend); real Spark patches need M1
# depends: knap-mcp repair loop, mock patch for "unclosed if block"
#
# seeded/verdict.knap is derived at take time: the shipped verdict
# template minus its first `{% endif %}` line (demo_seed_unclosed_if in
# demo/lib/env.sh), the same class as the eval corpus's unclosed-if seed.
Output demo/out/tapes/03-repair.mp4
Require glow
Require jq
Source demo/tapes/_settings.tape

Hide
Type "source demo/lib/env.sh && demo_seed_unclosed_if verdict"
Enter
Sleep 300ms
Show

# The seeded break: one line gone from the shipped template.
Type "diff templates/verdict.knap seeded/verdict.knap"
Enter
Sleep 2s

Type "export KNAP_TEMPLATES_DIR=seeded"
Enter
Sleep 500ms

# Pinned diagnostic from the engine (k4o), with line and column.
Type "knap-mcp validate verdict -d data/verdict.sample.json | jq '.diagnostics[0]'"
Enter
Sleep 3s

# One call from the client; the server runs render -> region -> patch -> re-render.
Type "knap-mcp repair verdict -d data/verdict.sample.json --target gfm --backend mock --out repaired.md | jq"
Enter
Sleep 4.5s

# The repaired render. The clip ends inside the pager, on the doc.
Type "glow -p repaired.md"
Enter
Sleep 4s

# TODO(M1): swap --backend mock for --backend spark once MODEL_API_KEY lands.
# TODO(repair owner): the CLI does not print the patch text, only steps.
#   SPEC asks to "show diagnostic, patch, re-render visibly"; surfacing the
#   region + patch per step (e.g. in steps[] or behind KNAP_DEBUG) would let
#   this beat show the patch itself.
