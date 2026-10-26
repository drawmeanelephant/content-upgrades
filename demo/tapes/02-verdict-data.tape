# Beat 2: ask for a verdict. Templates are fixed and server-side; the
# model only ever sees tool names and field shapes, and drafts values.
# target: 20s
# status: partial (tools/shape/data/validate ready; boris_ask needs B1+B3; live drafting needs M1)
# depends: knap-mcp (main), data/verdict.sample.json
Output demo/out/tapes/02-verdict-data.mp4
Require glow
Require jq
Source demo/tapes/_settings.tape

Hide
Type "source demo/lib/env.sh"
Enter
Sleep 300ms
Show

# Everything the model can touch: tool names. No template text.
Type `echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | knap-mcp | jq -r '.result.tools[].name'`
Enter
Sleep 2.5s

# The verdict template's shape: field names, never layout.
Type `knap-mcp templates | jq -c '.templates[] | select(.id=="verdict") | .shape.fields | keys'`
Enter
Sleep 2.5s

# The drafted data: values only.
Type "jq '{verdict, take, blockers}' data/verdict.sample.json"
Enter
Sleep 3s

Type "knap-mcp validate verdict -d data/verdict.sample.json | jq -c"
Enter
Sleep 3s

# TODO(B1+B3): retrieval from the frozen boris artifact comes first.
#   Type "knap-mcp boris-ask 'AcmeDB backups' | jq '.snippets[:3]'"
#   Enter
#   Sleep 3s
# TODO(M1 or MCP client): a real model drafts data.json from the snippets.
#   There is no CLI draft command; drafting happens in the MCP client
#   (Muse Code if viable) via knap_templates + knap_validate. Record that
#   with OBS, or swap data/verdict.sample.json for the frozen drafted file (I5).
