#!/bin/sh
# Gate for the frozen site: render the shipped samples with knap-mcp
# (markdown target), expect stage-check.sh to pass on verdict and apparatus,
# and fail on the hallucinated verdict (one invented source). Then run
# `knap-mcp publish-check` on every sample and hallucinated data set and
# expect the same verdict, the same codes, and the same line:column as
# `stage-check.sh --validate`.
#
# usage: selftest.sh
# needs: knap-mcp built (knap-mcp/zig-out/bin/knap-mcp), KNAP_K4O_PATH or k4o
#        on PATH, boris on PATH (or BORIS=...; KNAP_BORIS_PATH defaults to it)
set -eu

site=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
knap=$site/../knap-mcp
work=$(mktemp -d "${TMPDIR:-/tmp}/boris-selftest.XXXXXX")
trap 'rm -rf "$work"' EXIT
export KNAP_MCP_HOME="$work/knap-home"
export KNAP_BORIS_PATH="${KNAP_BORIS_PATH:-${BORIS:-boris}}"

# render <template> <data name>: writes $work/<data name>.md, prints the doc_id
render() {
  (cd "$knap" && ./zig-out/bin/knap-mcp render "$1" -d "data/$2.json" \
    --target markdown --out "$work/$2.md") | sed -n 's/.*"doc_id":"\([^"]*\)".*/\1/p'
}

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

render verdict verdict.sample > /dev/null
render apparatus apparatus.sample > /dev/null
render verdict verdict.hallucinated > /dev/null
expect 0 "$work/verdict.sample.md"
expect 0 "$work/apparatus.sample.md"
expect 1 "$work/verdict.hallucinated.md"
expect 0 --validate "$work/verdict.sample.md"
expect 1 --validate "$work/verdict.hallucinated.md"

# parity <template> <data name>: publish-check vs stage-check.sh --validate.
# Compared per diagnostic, in order: the code, and line:column wherever
# stage-check.sh maps one. Prints "<data name> <ok|FAIL> <codes>".
parity() {
  id=$(render "$1" "$2")
  set +e
  "$site/stage-check.sh" --validate "$work/$2.md" > /dev/null 2> "$work/$2.sc"
  sc_rc=$?
  (cd "$knap" && ./zig-out/bin/knap-mcp publish-check "$id") > "$work/$2.json" 2> "$work/$2.err"
  pc_rc=$?
  set -e
  LC_ALL=C awk -v doc="$work/$2.md" '
    index($0, doc ":") == 1 {
      rest = substr($0, length(doc) + 2)
      split(rest, a, ": ")
      i = index(rest, "error: ")
      code = substr(rest, i + 7); sub(/:.*/, "", code)
      print a[1], code; next
    }
    /^error: target / { print "-", "ELAYOUT"; next }
    /^error: [A-Z]+: / { code = substr($0, 8); sub(/:.*/, "", code); print "-", code; next }
    / \(staged as [^)]*\): error: / { code = $0; sub(/.*\): error: /, "", code); sub(/:.*/, "", code); print "-", code }
  ' "$work/$2.sc" > "$work/$2.sc.diags"
  jq -r '.diagnostics[] | "\(.line):\(.column) \(.code)"' "$work/$2.json" > "$work/$2.pc.diags" 2> /dev/null || : > "$work/$2.pc.diags"
  same=$(paste -d '|' "$work/$2.sc.diags" "$work/$2.pc.diags" | awk -F'|' -v n1="$(wc -l < "$work/$2.sc.diags")" -v n2="$(wc -l < "$work/$2.pc.diags")" '
    BEGIN { ok = (n1 + 0 == n2 + 0) }
    { split($1, s, " "); split($2, p, " ")
      if (s[2] != p[2] || (s[1] != "-" && s[1] != p[1])) ok = 0 }
    END { print ok ? "yes" : "no" }')
  codes=$(awk '{ printf "%s%s@%s", (NR > 1 ? "," : ""), $2, $1 }' "$work/$2.pc.diags")
  if [ "$same" = yes ] && [ "$sc_rc" -eq "$pc_rc" ]; then
    echo "parity: ok   $2 (exit $pc_rc) ${codes:-no diagnostics}"
  else
    echo "parity: FAIL $2: stage-check exit $sc_rc, publish-check exit $pc_rc" >&2
    sed 's/^/  stage-check:   /' "$work/$2.sc.diags" >&2
    sed 's/^/  publish-check: /' "$work/$2.pc.diags" "$work/$2.err" >&2
    fail=1
  fi
}

# want_codes <data name> <codes>: publish-check reported exactly these
want_codes() {
  got=$(jq -r '[.diagnostics[].code] | join(",")' "$work/$1.json" 2> /dev/null || echo "?")
  if [ "$got" != "$2" ]; then
    echo "selftest: FAIL: publish-check $1 reported '$got', want '$2'" >&2
    fail=1
  fi
}

# no_missing <data name>: every wiki-link and embed resolves
no_missing() {
  if jq -e '[.diagnostics[] | select(.code | startswith("EREFERENCE"))] | length > 0' "$work/$1.json" > /dev/null 2>&1; then
    echo "selftest: FAIL: publish-check $1 has unresolved wiki-links" >&2
    fail=1
  fi
}

parity verdict verdict.sample
parity apparatus apparatus.sample
parity release-notes release-notes.sample
parity reading-note reading-note.sample
parity verdict verdict.hallucinated
parity release-notes release-notes.hallucinated
want_codes verdict.sample ""
want_codes apparatus.sample ""
want_codes verdict.hallucinated EREFERENCEMISSING
no_missing release-notes.sample
no_missing reading-note.sample
jq -e '.diagnostics[] | select(.code == "EREFERENCEMISSING" and (.link // "" | startswith("![[")))' \
  "$work/release-notes.hallucinated.json" > /dev/null || {
  echo "selftest: FAIL: release-notes.hallucinated: no unresolved embed reported" >&2
  fail=1
}

"$site/build.sh" --check || fail=1

[ "$fail" = 0 ] && echo "selftest: ok"
exit "$fail"
