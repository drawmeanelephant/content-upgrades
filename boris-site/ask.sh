#!/bin/sh
# Ranked snippets from the frozen search index; no live indexing. This is
# the reference query for boris_ask (and the retrieval half of boris_check).
#
# usage: ask.sh [--claims] [-k N] <query>
#   --claims  rank claim pages only and attach each one's verdict tag and
#             `cites` sources from artifact/completion.json
#   -k N      hits to print (default 5)
#
# Prints one JSON object per hit, best first. Needs jq.
#
# Scoring follows the boris starter theme's browser search client, per query
# term (lowercased, split on whitespace) and per section:
#   title contains term +12, heading +8, text +2, code +1;
#   then +1 for a level-1 section and +5 when the whole query appears.
# A document's score is its best section's. One deliberate change: a section
# needs at least one term hit, so the level-1 bonus alone never matches.
# Ties sort by path, then section order.
set -eu

claims=false
k=5
while [ $# -gt 0 ]; do
  case $1 in
    --claims) claims=true ;;
    -k) k=$2; shift ;;
    -*) echo "usage: ask.sh [--claims] [-k N] <query>" >&2; exit 2 ;;
    *) break ;;
  esac
  shift
done
[ $# -eq 1 ] || { echo "usage: ask.sh [--claims] [-k N] <query>" >&2; exit 2; }

art=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/artifact
jq -c --arg q "$1" --argjson k "$k" --argjson claims "$claims" \
  --slurpfile meta "$art/completion.json" '
def norm: ascii_downcase | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
def has($t): if $t == "" then false else index($t) != null end;
def excerpt($terms):
  ((.text // "") | if . == "" then null else . end) // ((.code // "") | if . == "" then null else . end) // .heading
  | gsub("\\s+"; " ") as $src
  | ([$terms[] | . as $t | ($src | ascii_downcase | index($t))] | map(select(. != null)) | first) as $at
  | (if $at == null then 0 else ([$at - 48, 0] | max) end) as $start
  | (if $start > 0 then "…" else "" end) + $src[$start:$start + 150]
    + (if $start + 150 < ($src | length) then "…" else "" end);

if .format != "boris-rendered-search-index" or .schema_version != 1
then error("unsupported search index") else . end
| ($meta[0].entities | map({key: .id, value: .}) | from_entries) as $ent
| ($q | norm) as $phrase
| ($phrase | split(" ") | map(select(length > 0))) as $terms
| [ .documents[]
    | (.path | sub("\\.html$"; "")) as $id
    | select($claims | not or (($ent[$id].tags // []) | index(["claim"]) != null))
    | (.title | norm) as $title
    | . as $doc
    | [ .sections | to_entries[]
        | .key as $i | .value as $s
        | ([$s.heading, $s.text, $s.code] | map(norm)) as $v
        | ([$terms[] | . as $t
            | (if $title | has($t) then 12 else 0 end)
            + (if $v[0] | has($t) then 8 else 0 end)
            + (if $v[1] | has($t) then 2 else 0 end)
            + (if $v[2] | has($t) then 1 else 0 end)] | add // 0) as $base
        | select($base > 0)
        | {score: ($base + (if $s.level == 1 then 1 else 0 end)
            + (if ($title | has($phrase)) or ($v | any(has($phrase))) then 5 else 0 end)),
           i: $i, s: $s} ]
    | max_by(.score)? // empty
    | {score, id: $id, path: $doc.path, fragment: .s.fragment, title: $doc.title,
       heading: .s.heading, snippet: (.s | excerpt($terms)), i} ]
| sort_by(-.score, .path, .i)
| .[:$k][]
| del(.i)
| if $claims then
    . + {verdict: (($ent[.id].tags // []) - ["claim"] | first),
         cites: [($ent[.id].relations // [])[] | select(.kind == "cites") | .target
                 | {id: ., title: $ent[.].title}]}
  else . end
' "$art/search-index.json"
