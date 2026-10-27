#!/usr/bin/env bash
# Beat-8 numbers card: every value measured, each carrying its source.
#
#   demo/card/build.sh          # writes numbers.json + numbers.png
#   demo/card/build.sh --json   # numbers.json only (no Chrome)
#
# Sources (all offline; nothing calls a live model):
#   repair convergence: knap-mcp/eval/results/live/{acp-seeds,
#     acp-seeds.2nap,devin-wonder/repair-seeds,devin-wonder/repair-seeds.2nap}.out
#     (I2), plus a fresh `knap-mcp eval --backend mock` as the control.
#   density climb:      .../live/{acp.txt,devin-wonder/ratchet.out,mock.txt}
#     (I3, scorer density/2).
#   conformance:        eval/conformance/results/k4o-main-<pin>.json plus the
#     base -> #70 -> #71 lineage headline (K3: never a main->#70->#71 line).
#   server size:        cat $(find knap-mcp/src/ -name '*.zig') | wc -l.
#   calls × mean slice: the `calls:` instrumentation line in each .out file.
#
# Token-cost numbers are deliberately absent: ACP usage counts the devin
# agent's own ~13.5k-token system prompt on every call (LIVE.md finding 3),
# so those counts are agent-inclusive, not model cost.
set -euo pipefail

CARD=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$CARD/../.." && pwd)
KNAP=$ROOT/knap-mcp
LIVE=$KNAP/eval/results/live
CONF=$KNAP/eval/conformance/results
OUT=$ROOT/demo/out/card
BIN=$KNAP/zig-out/bin/knap-mcp

need() { command -v "$1" >/dev/null 2>&1 || { echo "card/build.sh: missing '$1'" >&2; exit 1; }; }
need jq
need awk

: "${KNAP_K4O_PATH:=$("$ROOT/scripts/engines.sh" path k4o)}"
: "${KNAP_DOGBED_PATH:=$("$ROOT/scripts/engines.sh" path dogbed)}"
export KNAP_K4O_PATH KNAP_DOGBED_PATH
unset KNAP_TEMPLATES_DIR

k4o_pin=$(basename "$(dirname "$KNAP_K4O_PATH")")
dogbed_pin=$(basename "$(dirname "$KNAP_DOGBED_PATH")")
CONF_JSON=$CONF/k4o-main-${k4o_pin#k4o-}.json
[ -f "$CONF_JSON" ] || {
  echo "card/build.sh: no conformance result for $k4o_pin ($CONF_JSON)" >&2
  exit 1
}
[ -x "$BIN" ] || (cd "$KNAP" && zig build) || { echo "card/build.sh: zig build failed" >&2; exit 1; }

mkdir -p "$OUT"
MOCK_STORE=$(mktemp -d "${TMPDIR:-/tmp}/knap-card.XXXXXX")
trap 'rm -rf "$MOCK_STORE"' EXIT

# conv: "passed/total iters exact" from the `converged` summary line (stdin).
conv() { awk '/^converged /{printf "%s %s %s", $2, $6, $8}'; }
# callsline: "calls mean-slice-B" from the `calls:` instrumentation line.
callsline() { awk '/^calls: /{printf "%s %s", $2, $5}'; }
# rat: "ok n bestcase bestgain" from the ratchet table's case rows (stdin).
rat() {
  awk -F'|' 'NF > 2 && $(NF-1) ~ /ok|FAIL/ {n++; if ($(NF-1) ~ /ok/) ok++; if ($5+0 > g) {g = $5 + 0; c = $2}}
    END {gsub(/^ +| +$/, "", c); printf "%d %d %s %.1f", ok, n, c, g}'
}

printf '== repair eval, eval/seeds.json (22 breaks) ==\n'
m22=$(cd "$KNAP" && KNAP_MCP_HOME=$MOCK_STORE "$BIN" eval --corpus eval/seeds.json --backend mock 2>/dev/null)
read -r m22_c m22_i m22_x <<< "$(conv <<< "$m22")"
read -r m22_n m22_s <<< "$(callsline <<< "$m22")"
read -r s22_c s22_i s22_x <<< "$(conv < "$LIVE/acp-seeds.out")"
read -r s22_n s22_s <<< "$(callsline < "$LIVE/acp-seeds.out")"
read -r w22_c w22_i w22_x <<< "$(conv < "$LIVE/devin-wonder/repair-seeds.out")"
read -r w22_n w22_s <<< "$(callsline < "$LIVE/devin-wonder/repair-seeds.out")"
printf 'mock (control)          %s   <- eval --backend mock @%s\n' "$m22_c" "$(git -C "$ROOT" rev-parse --short HEAD)"
printf 'acp: devin summarizer   %s   <- eval/results/live/acp-seeds.out\n' "$s22_c"
printf 'Muse Wonder via ACP     %s   <- eval/results/live/devin-wonder/repair-seeds.out\n' "$w22_c"

printf '== repair eval, eval/seeds.2nap.json (167 breaks) ==\n'
m2n=$(cd "$KNAP" && KNAP_MCP_HOME=$MOCK_STORE "$BIN" eval --corpus eval/seeds.2nap.json --backend mock 2>/dev/null)
read -r m2n_c m2n_i m2n_x <<< "$(conv <<< "$m2n")"
read -r m2n_n m2n_s <<< "$(callsline <<< "$m2n")"
read -r s2n_c s2n_i s2n_x <<< "$(conv < "$LIVE/acp-seeds.2nap.out")"
read -r s2n_n s2n_s <<< "$(callsline < "$LIVE/acp-seeds.2nap.out")"
read -r w2n_c w2n_i w2n_x <<< "$(conv < "$LIVE/devin-wonder/repair-seeds.2nap.out")"
read -r w2n_n w2n_s <<< "$(callsline < "$LIVE/devin-wonder/repair-seeds.2nap.out")"
printf 'mock (control)          %s   <- eval --backend mock @%s\n' "$m2n_c" "$(git -C "$ROOT" rev-parse --short HEAD)"
printf 'acp: devin summarizer   %s   <- eval/results/live/acp-seeds.2nap.out\n' "$s2n_c"
printf 'Muse Wonder via ACP     %s   <- eval/results/live/devin-wonder/repair-seeds.2nap.out\n' "$w2n_c"

printf '== density ratchet, eval/ratchet.live.json (9 cases, density/2) ==\n'
read -r rm_ok rm_n rm_bc rm_g <<< "$(rat < "$LIVE/mock.txt")"
read -r rs_ok rs_n rs_bc rs_g <<< "$(rat < "$LIVE/acp.txt")"
read -r rw_ok rw_n rw_bc rw_g <<< "$(rat < "$LIVE/devin-wonder/ratchet.out")"
read -r rm_n2 rm_s2 <<< "$(callsline < "$LIVE/mock.txt")"
read -r rs_n2 rs_s2 <<< "$(callsline < "$LIVE/acp.txt")"
read -r rw_n2 rw_s2 <<< "$(callsline < "$LIVE/devin-wonder/ratchet.out")"
printf 'mock (control)          %s/%s ok, best +%s   <- eval/results/live/mock.txt\n' "$rm_ok" "$rm_n" "$rm_g"
printf 'acp: devin summarizer   %s/%s ok, best +%s   <- eval/results/live/acp.txt\n' "$rs_ok" "$rs_n" "$rs_g"
printf 'Muse Wonder via ACP     %s/%s ok, best +%s   <- eval/results/live/devin-wonder/ratchet.out\n' "$rw_ok" "$rw_n" "$rw_g"

printf '== conformance + server ==\n'
conf_totals=$(jq -c .totals "$CONF_JSON")
conf_pass=$(jq -r '.totals.pass' "$CONF_JSON")
conf_cases=$(jq -r '.totals.cases' "$CONF_JSON")
k4o_ver=$(jq -r .engine.version "$CONF_JSON")
lineage=$(jq -r .headline "$CONF/summary-lineage.json")
loc=$(find "$KNAP/src" -name '*.zig' -exec cat {} + | wc -l | tr -d ' ')
printf 'k4o conformance         %s/%s   <- eval/conformance/results/k4o-main-%s.json\n' "$conf_pass" "$conf_cases" "${k4o_pin#k4o-}"
printf 'lineage (not main)      %s\n' "$lineage"
printf 'server                  %s lines   <- cat $(find knap-mcp/src -name %s) | wc -l\n' "$loc" "'*.zig'"

git_sha=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
date_utc=$(date -u +%F)

jq -n \
  --arg date "$date_utc" --arg git "$git_sha" \
  --arg k4o "$k4o_pin" --arg k4o_ver "$k4o_ver" --arg dogbed "$dogbed_pin" \
  --arg lineage "$lineage" --arg loc "$loc" --arg conf_src "eval/conformance/results/k4o-main-${k4o_pin#k4o-}.json" \
  --arg m22_c "$m22_c" --arg m22_d "exact $m22_x · mean $m22_i iters" --arg m22_cs "$m22_n × $m22_s B" \
  --arg s22_c "$s22_c" --arg s22_d "exact $s22_x · mean $s22_i iters" --arg s22_cs "$s22_n × $s22_s B" \
  --arg w22_c "$w22_c" --arg w22_d "exact $w22_x · mean $w22_i iters" --arg w22_cs "$w22_n × $w22_s B" \
  --arg m2n_c "$m2n_c" --arg m2n_d "exact $m2n_x · mean $m2n_i iters" --arg m2n_cs "$m2n_n × $m2n_s B" \
  --arg s2n_c "$s2n_c" --arg s2n_d "exact $s2n_x · mean $s2n_i iters" --arg s2n_cs "$s2n_n × $s2n_s B" \
  --arg w2n_c "$w2n_c" --arg w2n_d "exact $w2n_x · mean $w2n_i iters" --arg w2n_cs "$w2n_n × $w2n_s B" \
  --arg rm_ok "$rm_ok/$rm_n" --arg rm_g "+$rm_g $rm_bc" --arg rm_cs "$rm_n2 × $rm_s2 B" \
  --arg rs_ok "$rs_ok/$rs_n" --arg rs_g "+$rs_g $rs_bc" --arg rs_cs "$rs_n2 × $rs_s2 B" \
  --arg rw_ok "$rw_ok/$rw_n" --arg rw_g "+$rw_g $rw_bc" --arg rw_cs "$rw_n2 × $rw_s2 B" \
  --arg conf "$conf_pass/$conf_cases" \
  '{
    card: "knap-mcp: the numbers, measured",
    generated: {date_utc: $date, git: $git, by: "demo/card/build.sh"},
    engines: {k4o: {pin: $k4o, version: $k4o_ver}, dogbed: {pin: $dogbed}},
    scorer: "density/2",
    columns: [
      {id: "mock", label: "mock (control)"},
      {id: "summarizer", label: "acp: devin summarizer"},
      {id: "wonder", label: "Muse Wonder 1.0 via ACP (devin)"}
    ],
    rows: [
      {metric: "repair: converged", corpus: "eval/seeds.json · 22 seeded breaks",
       cells: [
         {value: $m22_c, detail: $m22_d, source: "eval --backend mock, this commit"},
         {value: $s22_c, detail: $s22_d, source: "eval/results/live/acp-seeds.out"},
         {value: $w22_c, detail: $w22_d, source: "eval/results/live/devin-wonder/repair-seeds.out"}]},
      {metric: "repair: converged", corpus: "eval/seeds.2nap.json · 167 seeded breaks",
       cells: [
         {value: $m2n_c, detail: $m2n_d, source: "eval --backend mock, this commit"},
         {value: $s2n_c, detail: $s2n_d, source: "eval/results/live/acp-seeds.2nap.out"},
         {value: $w2n_c, detail: $w2n_d, source: "eval/results/live/devin-wonder/repair-seeds.2nap.out"}]},
      {metric: "density ratchet: cases ok", corpus: "eval/ratchet.live.json · 9 cases · density/2",
       cells: [
         {value: $rm_ok, detail: ("best " + $rm_g), source: "eval/results/live/mock.txt"},
         {value: $rs_ok, detail: ("best " + $rs_g), source: "eval/results/live/acp.txt"},
         {value: $rw_ok, detail: ("best " + $rw_g), source: "eval/results/live/devin-wonder/ratchet.out"}]},
      {metric: "repair calls × mean slice", corpus: "eval/seeds.2nap.json · repair eval",
       cells: [
         {value: $m2n_cs, source: "eval --backend mock, this commit"},
         {value: $s2n_cs, source: "eval/results/live/acp-seeds.2nap.out"},
         {value: $w2n_cs, source: "eval/results/live/devin-wonder/repair-seeds.2nap.out"}]},
      {metric: "ratchet calls × mean slice", corpus: "eval/ratchet.live.json · density/2",
       cells: [
         {value: $rm_cs, source: "eval/results/live/mock.txt"},
         {value: $rs_cs, source: "eval/results/live/acp.txt"},
         {value: $rw_cs, source: "eval/results/live/devin-wonder/ratchet.out"}]}
    ],
    facts: [
      {label: "k4o conformance", value: $conf,
       detail: ("pin " + $k4o + " · " + $k4o_ver + " · " + $lineage),
       source: $conf_src},
      {label: "server", value: ($loc + " lines of Zig"),
       detail: "knap-mcp/src/*.zig",
       source: "cat $(find knap-mcp/src -name '"'"'*.zig'"'"') | wc -l"}
    ],
    footnotes: [
      "ACP columns measure model plus agent harness (one devin acp session per call), not a direct API.",
      "No token-cost numbers: each ACP call carries ~13.5k tokens of agent system prompt (LIVE.md finding 3).",
      "Sources: knap-mcp/eval/results/live/ (I2/I3), eval/conformance/results/ (K3/K5), a fresh mock eval, src LOC."
    ]
  }' > "$CARD/numbers.json"

printf 'wrote %s\n' "${CARD#"$ROOT"/}/numbers.json"

[ "${1:-}" = "--json" ] && exit 0

chrome=${KNAP_CHROME:-}
if [ -z "$chrome" ]; then
  for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Chromium.app/Contents/MacOS/Chromium" \
    "$(command -v google-chrome || true)" "$(command -v chromium || true)"; do
    [ -n "$c" ] && [ -x "$c" ] && chrome=$c && break
  done
fi
[ -n "$chrome" ] || { echo "card/build.sh: no Chrome/Chromium found; numbers.json written, png skipped" >&2; exit 1; }

# Inline numbers.json into the template (file:// pages cannot fetch it).
awk 'NR == FNR {j = j $0 "\n"; next} /__NUMBERS_JSON__/ {printf "const DATA = %s;\n", j; next} {print}' \
  "$CARD/numbers.json" "$CARD/card.html" > "$OUT/card.html"

profile=$(mktemp -d "${TMPDIR:-/tmp}/knap-card-chrome.XXXXXX")
"$chrome" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --user-data-dir="$profile" --window-size=1920,1080 \
  --screenshot="$CARD/numbers.png" "file://$OUT/card.html" 2>/dev/null
rm -rf "$profile"
printf 'wrote %s (1920x1080)\n' "${CARD#"$ROOT"/}/numbers.png"
