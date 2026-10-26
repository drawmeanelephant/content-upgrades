#!/bin/sh
# Stage one rendered knap doc into a throwaway copy of the frozen boris site
# and check that every wiki-link in it resolves. The frozen site is never
# written. This is the reference behavior for knap_publish_check.
#
# usage: stage-check.sh [--validate] [--keep] <doc.md>
#   --validate  run `boris validate` (renders pages; also checks #heading
#               fragments) instead of `boris check` (graph only, faster)
#   --keep      keep the staging dir and print its path
#
# exit: 0 every reference resolves
#       1 content diagnostics (unresolved wiki-link, bad frontmatter, ...)
#       2 usage
#       3 boris I/O or system failure (boris's own exit code otherwise)
#
# Staging adapts the doc to boris's grammar without touching its body lines:
#   - knap frontmatter (open YAML) becomes boris frontmatter with `title` only;
#     boris's frontmatter is a closed key set, so `year:` or a YAML list fails.
#   - [[Target]] becomes [[slug(Target)|Target]]. Boris ids cannot contain
#     spaces; slug = lowercase ASCII, keep [a-z0-9/], every other run -> "-".
#     Targets already in slug form, like [[claims/backup-gap]], are untouched.
# Diagnostics are mapped back to the original doc's line and column
# (boris reports 1-based file lines and 1-based byte columns).
set -eu

BORIS=${BORIS:-boris}
mode=check
keep=0
doc=

usage() {
  echo "usage: stage-check.sh [--validate] [--keep] <doc.md>" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case $1 in
    --validate) mode=validate ;;
    --keep) keep=1 ;;
    -*) usage ;;
    *) [ -z "$doc" ] || usage; doc=$1 ;;
  esac
  shift
done
[ -n "$doc" ] || usage
if [ ! -f "$doc" ]; then
  echo "stage-check: no such file: $doc" >&2
  exit 2
fi

site=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
stage=$(mktemp -d "${TMPDIR:-/tmp}/boris-stage.XXXXXX")
cleanup() {
  if [ "$keep" = 1 ]; then
    echo "stage-check: kept $stage" >&2
  else
    rm -rf "$stage"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

cp -R "$site/content" "$site/themes" "$stage/"

name=$(printf '%s' "$(basename -- "$doc" .md)" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-')
case $name in "" | .*) name=doc$name ;; esac
rel=staged/$name.md
mkdir -p "$stage/content/staged"
: > "$stage/links.tsv"

# links.tsv: staged_line  staged_col  original_line  original_col  slug  original_link
# delta:     original_line - staged_line for body lines
LC_ALL=C awk -v links="$stage/links.tsv" -v deltafile="$stage/delta" '
function slug(s) {
  s = tolower(s)
  gsub(/[^a-z0-9\/]+/, "-", s)
  gsub(/^[-\/]+/, "", s)
  gsub(/[-\/]+$/, "", s)
  return s
}
function rewrite(line,    out, consumed, m, inner, pipe, target, label, hash, frag, id, rep) {
  out = ""
  consumed = 0
  while (match(line, /\[\[[^]]+\]\]/)) {
    m = substr(line, RSTART, RLENGTH)
    inner = substr(m, 3, length(m) - 4)
    pipe = index(inner, "|")
    if (pipe) { target = substr(inner, 1, pipe - 1); label = substr(inner, pipe + 1) }
    else { target = inner; label = target }
    hash = index(target, "#")
    if (hash) { frag = substr(target, hash); target = substr(target, 1, hash - 1) }
    else frag = ""
    id = slug(target)
    rep = (id == "" || id == target) ? m : "[[" id frag "|" label "]]"
    out = out substr(line, 1, RSTART - 1)
    printf "%d\t%d\t%d\t%d\t%s\t%s\n", staged + 1, length(out) + 1, NR, consumed + RSTART, id, m > links
    out = out rep
    consumed += RSTART + RLENGTH - 1
    line = substr(line, RSTART + RLENGTH)
  }
  return out line
}
NR == 1 && $0 == "---" { fm = 1; next }
fm == 1 {
  if ($0 == "---") {
    fm = 2
    if (title != "") {
      print "---"
      # boris double quotes allow no escapes and no embedded quote
      print (index(title, "\"") ? "title: " title : "title: \"" title "\"")
      print "---"
      staged = 3
    }
    next
  }
  if (title == "" && $0 ~ /^title:/) {
    title = substr($0, 7)
    sub(/^[ \t]+/, "", title)
    sub(/[ \t]+$/, "", title)
    if (title ~ /^".*"$/) title = substr(title, 2, length(title) - 2)
  }
  next
}
{ print rewrite($0); staged++ }
END {
  if (fm == 1) { print "stage-check: unclosed frontmatter" > "/dev/stderr"; exit 1 }
  print NR - staged > deltafile
}
' "$doc" > "$stage/content/$rel"

nlinks=$(wc -l < "$stage/links.tsv" | tr -d ' ')

cd "$stage"
set +e
if [ "$mode" = validate ]; then
  "$BORIS" validate --input content --report report.json --quiet 2> stderr.txt
else
  "$BORIS" check --input content --format json --report report.json --quiet 2> stderr.txt
fi
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
  pages=$(sed -n 's/^ *"pages": \([0-9][0-9]*\),*$/\1/p' report.json | head -n 1)
  echo "stage-check: ok: $doc staged as $rel; $nlinks wiki-link(s) resolve against the frozen site${pages:+ ($pages pages)} [boris $mode]"
  exit 0
fi
if [ "$rc" -ne 1 ]; then
  cat stderr.txt >&2
  case $rc in 2 | 3) exit "$rc" ;; *) exit 3 ;; esac
fi

# Boris prints one line per diagnostic:
#   error: CODE: path:line:col: message [remediation]
# A diagnostic on a wiki-link maps through links.tsv; any other body line
# shifts by delta. Frontmatter diagnostics point at the generated frontmatter.
LC_ALL=C awk -v links=links.tsv -v rel="$rel" -v doc="$doc" -v delta="$(cat delta)" '
BEGIN { FS = "\t" }
FILENAME == links { k = $1 "," $2; oline[k] = $3; ocol[k] = $4; id[k] = $5; link[k] = $6; next }
/^error: / {
  rest = substr($0, 8)
  i = index(rest, ": "); code = substr(rest, 1, i - 1); rest = substr(rest, i + 2)
  i = index(rest, ": "); loc = substr(rest, 1, i - 1); msg = substr(rest, i + 2)
  i = index(msg, " ["); if (i) msg = substr(msg, 1, i - 1)
  n = split(loc, a, ":")
  errors++
  k = a[n - 1] "," a[n]
  if (n >= 3 && index(loc, rel ":") == 1 && (k in oline)) {
    printf "%s:%d:%d: error: %s: %s\n", doc, oline[k], ocol[k], code, msg
    if (link[k] != "[[" id[k] "]]") printf "  %s -> %s\n", link[k], id[k]
  } else if (n >= 3 && index(loc, rel ":") == 1 && code !~ /^EFRONTMATTER/) {
    printf "%s:%d:%d: error: %s: %s\n", doc, a[n - 1] + delta, a[n], code, msg
  } else if (index(loc, rel ":") == 1) {
    printf "%s (staged as %s): error: %s: %s\n", doc, loc, code, msg
  } else {
    print
  }
  next
}
{ print }
END { print "stage-check: FAIL: " errors + 0 " diagnostic(s); " doc " does not resolve against the frozen site" }
' links.tsv stderr.txt >&2
exit 1
