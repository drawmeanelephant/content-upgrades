# Apply one tone's canned mock replies to a template's data: the reference
# for what `knap-mcp voice --backend mock` must produce.
#
#   jq --arg template verdict --slurpfile mock prompts/voice/mock/spicy.jsonl \
#      -f eval/voice/apply-mock.jq data/verdict.sample.json
#
# A mock line applies when its template matches and the value at its field
# path equals its input; then the value becomes its output. Paths look like
# `take`, `blockers[0]`, `receipts[1][0]`, `breaking[0].change`.
#
# With `--arg mode report` it prints {"lines", "applied", "missed": [fields]}
# instead of the data.

def parse_path:
  [ scan("[^.\\[\\]]+|\\[[0-9]+\\]")
    | if startswith("[") then .[1:-1] | tonumber else . end ];

def value_at($p): try getpath($p) catch null;

. as $data
| [ $mock[] | select(.template == $template) ] as $lines
| [ $lines[] | (.field | parse_path) as $p | select(($data | value_at($p)) == .input) ] as $hits
| if ($ARGS.named.mode // "data") == "report" then
    { lines: ($lines | length),
      applied: ($hits | length),
      missed: [ $lines[] | (.field | parse_path) as $p
                | select(($data | value_at($p)) != .input) | .field ] }
  else
    reduce $hits[] as $m ($data; setpath($m.field | parse_path; $m.output))
  end
