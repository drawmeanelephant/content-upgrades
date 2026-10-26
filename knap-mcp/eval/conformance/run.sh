#!/bin/sh
# k4o conformance on the vendored knap corpus at the pinned k4o revisions.
#
#   eval/conformance/run.sh [out-dir]      # default: eval/conformance/results
#
# Engines come from $KNAP_ENGINES_DIR (default ~/.cache/knap-engines) as
# k4o-<sha7>/k4o, built from `git archive <sha>` with -Doptimize=ReleaseSafe.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
mcp=$(cd "$here/../.." && pwd)
out=${1:-$here/results}
engines=${KNAP_ENGINES_DIR:-$HOME/.cache/knap-engines}
mkdir -p "$out"
out=$(cd "$out" && pwd)
cd "$mcp"

run() { # <label> <sha> <slug>
  bin="$engines/k4o-$(printf %s "$2" | cut -c1-7)/k4o"
  if [ ! -x "$bin" ]; then
    echo "run.sh: missing $bin; build k4o $2 there first" >&2
    exit 1
  fi
  zig run eval/conformance/runner.zig -- run --k4o "$bin" --corpus ../corpus/render.json \
    --label "$1" --revision "$2" --json "$out/k4o-$3.json" > "$out/k4o-$3.md"
}

run main bdfb838a115e86483d9ef1f14d6768a9b9ea0754 main-bdfb838
run base 019fac3c27d552f65b3e09c7e6135c1e8ae1e452 base-019fac3
run '#70' 2436fee774221534fff876a5188550be7724c229 pr70-2436fee
run '#71' f97c5dbbaec81ded2d90de66b0f4e62bb4c475b1 pr71-f97c5db

# The headline order the numbers card asks for, then the same-lineage view:
# #70 and #71 stack on 019fac3, not on current main.
zig run eval/conformance/runner.zig -- summarize --json "$out/summary.json" \
  "$out/k4o-main-bdfb838.json" "$out/k4o-pr70-2436fee.json" "$out/k4o-pr71-f97c5db.json" > "$out/summary.md"
zig run eval/conformance/runner.zig -- summarize --json "$out/summary-lineage.json" \
  "$out/k4o-base-019fac3.json" "$out/k4o-pr70-2436fee.json" "$out/k4o-pr71-f97c5db.json" > "$out/summary-lineage.md"
cat "$out/summary.md"
