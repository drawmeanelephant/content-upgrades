# Beat 2: ask for a verdict. Templates are fixed and server-side; the
# model only ever sees tool names and field shapes, and drafts values.
# The drafted data is the frozen I5 take, labeled on screen from
# frozen/provenance.json (Muse Wonder 1.0 via ACP (devin, low thinking)).
# It validates against the shape but reaches its own verdict ("skip
# it") — beat 4 renders the curated data/verdict.sample.json, not this
# draft (I5 continuity note).
# target: 20s
# status: ready (frozen drafted data + shipped boris_ask)
# depends: knap-mcp (main), demo/frozen/, boris_ask (B3, shipped)
#
# frozen/ is a symlink to demo/frozen made in the hidden preamble, so
# on-screen paths name the frozen inputs.
Output demo/out/tapes/02-verdict-data.mp4
Require jq
Source demo/tapes/_settings.tape

Hide
Type "source demo/lib/env.sh && ln -s $DEMO_ROOT/demo/frozen frozen"
Enter
Sleep 400ms
Show

# Everything the model can touch: tool names. No template text.
Type `echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | knap-mcp | jq -r '.result.tools[].name'`
Enter
Sleep 800ms

# The verdict template's shape: field names, never layout.
Type `knap-mcp templates | jq -r '.templates[] | select(.id=="verdict") | .shape.fields | keys[]'`
Enter
Sleep 1.2s

# The evidence store: ranked hits from the frozen boris artifact (the draft itself was given only the sample's sources array).
Type "knap-mcp boris-ask 'AcmeDB backups' --limit 3 | jq -c '.results[] | {score,title}'"
Enter
Sleep 1s

# Who drafted it: the frozen take's label, straight from the manifest.
Type "jq -r .label frozen/provenance.json"
Enter
Sleep 500ms

# The model's draft: values only, and it reaches its own verdict.
Type "jq '{verdict, take, blockers}' frozen/02-verdict.drafted.json"
Enter
Sleep 1.3s

# The model's draft validates against the shape. (Beat 4 renders the
# curated data/verdict.sample.json — the doc is not rendered from this draft.)
Type "knap-mcp validate verdict -d frozen/02-verdict.drafted.json | jq -c"
Enter
Sleep 1.5s
