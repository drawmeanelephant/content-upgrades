#!/bin/sh
# Gate for the frozen site: render the shipped verdict and apparatus samples
# with knap-mcp (markdown target), expect stage-check.sh to pass on both, then
# inject one invented [[wikilink]] and expect it to fail.
#
# usage: selftest.sh
# needs: knap-mcp built (knap-mcp/zig-out/bin/knap-mcp), KNAP_K4O_PATH or k4o
#        on PATH, boris on PATH (or BORIS=...)
set -eu

site=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
knap=$site/../knap-mcp
work=$(mktemp -d "${TMPDIR:-/tmp}/boris-selftest.XXXXXX")
trap 'rm -rf "$work"' EXIT
export KNAP_MCP_HOME="$work/knap-home"

render() {
  (cd "$knap" && ./zig-out/bin/knap-mcp render "$1" -d "data/$1.sample.json" \
    --target markdown --out "$work/$1.md" > /dev/null)
}
render verdict
render apparatus

# One hallucinated source line, inserted before the last real source.
awk '/^- \[\[AcmeDB launch post\]\]/ && !done {
  print "- [[AcmeDB SOC 2 audit report]] — https://example.com/acmedb/soc2 (audit, reliability high, gaf high)"
  done = 1
} { print }' "$work/verdict.md" > "$work/verdict.hallucinated.md"

fail=0
expect() {
  want=$1; shift
  set +e
  "$site/stage-check.sh" "$@"
  got=$?
  set -e
  if [ "$got" -ne "$want" ]; then
    echo "selftest: FAIL: stage-check.sh $* exited $got, want $want" >&2
    fail=1
  fi
}
expect 0 "$work/verdict.md"
expect 0 "$work/apparatus.md"
expect 1 "$work/verdict.hallucinated.md"
expect 0 --validate "$work/verdict.md"
expect 1 --validate "$work/verdict.hallucinated.md"
"$site/build.sh" --check || fail=1

[ "$fail" = 0 ] && echo "selftest: ok"
exit "$fail"
