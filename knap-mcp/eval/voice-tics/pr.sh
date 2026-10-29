#!/bin/sh
# Score filed voice-pass PRs as shipped (VOICE-TICS, #382): every changed
# content/ record at the PR's merge base vs its head, through
# `knap-mcp voice-tics`. A batch review gets its tic numbers here before
# it is merged, rather than from a hand count afterwards.
#
#   knap-mcp/eval/voice-tics/pr.sh [--repo o/r] [--out dir] [--min-runs n] <pr>...
#
# One profile per PR plus an `all` row when more than one PR is given,
# printed as a markdown table. Records land in <out>/pr-<n>/{before,after}/
# (default ~/.cache/knap-voice-tics/prs) and are reused on rerun. Needs gh
# (authenticated) and jq.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
knap=$(cd "$here/../.." && pwd)
die() { echo "voice-tics pr: $*" >&2; exit 1; }

repo=drawmeanelephant/filed.fyi min_runs=3 prs=''
out=${XDG_CACHE_HOME:-$HOME/.cache}/knap-voice-tics/prs
while [ $# -gt 0 ]; do
    case $1 in
    --repo) repo=${2:?}; shift ;;
    --out) out=${2:?}; shift ;;
    --min-runs) min_runs=${2:?}; shift ;;
    -h | --help) sed -n '2,/^set -eu/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option '$1' (see --help)" ;;
    *) prs="$prs $1" ;;
    esac
    shift
done
[ -n "$prs" ] || die "name at least one PR number"
command -v gh >/dev/null 2>&1 || die "needs gh"
command -v jq >/dev/null 2>&1 || die "needs jq"
bin=${KNAP_MCP_BIN:-$knap/zig-out/bin/knap-mcp}
[ -x "$bin" ] || (cd "$knap" && zig build) || die "zig build failed"

raw() { gh api -H 'Accept: application/vnd.github.raw' "repos/$repo/contents/$1?ref=$2"; }

all=''
rows=$(mktemp)
trap 'rm -f "$rows"' EXIT
for n in $prs; do
    dir=$out/pr-$n
    mkdir -p "$dir/before" "$dir/after"
    head=$(gh pr view "$n" -R "$repo" --json headRefOid --jq .headRefOid) || die "cannot read PR $n"
    base=$(gh pr view "$n" -R "$repo" --json baseRefOid --jq .baseRefOid)
    mb=$(gh api "repos/$repo/compare/$base...$head" --jq .merge_base_commit.sha)
    gh api "repos/$repo/pulls/$n/files?per_page=100" --paginate \
        --jq '.[] | select(.status == "modified" and (.filename | startswith("content/")) and (.filename | endswith(".md"))) | .filename' >"$dir/files.txt"
    pairs=''
    while read -r f; do
        k=$(echo "$f" | tr / _)
        [ -s "$dir/before/$k" ] && [ -s "$dir/.$k.$head" ] || {
            raw "$f" "$mb" >"$dir/before/$k" && raw "$f" "$head" >"$dir/after/$k" && : >"$dir/.$k.$head"
        } || die "cannot fetch $f for PR $n"
        pairs="$pairs $dir/before/$k $dir/after/$k"
    done <"$dir/files.txt"
    [ -n "$pairs" ] || { echo "voice-tics pr: PR $n changes no content/ records" >&2; continue; }
    # shellcheck disable=SC2086
    "$bin" voice-tics --label "$repo#$n" --min-runs "$min_runs" $pairs >"$dir/profile.json"
    echo "$dir/profile.json" >>"$rows"
    all="$all$pairs"
done
if [ "$(echo "$prs" | wc -w)" -gt 1 ] && [ -n "$all" ]; then
    # shellcheck disable=SC2086
    "$bin" voice-tics --label "$repo all of$prs" --min-runs "$min_runs" $all >"$out/all.json"
    echo "$out/all.json" >>"$rows"
fi

echo "| batch | records | runs | changed | tic runs | lexicon /100 | ironic italics | dashes | reworded | repeat share | distinct | top repeats |"
echo "|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|"
while read -r f; do
    jq -r 'def pct(n; d): if d == 0 then "-" else "\((100 * n / d) | floor)%" end;
        "| \(.label) | \(.pairs) | \(.runs) | \(.changed) | \(pct(.tic_runs; .changed)) | \(.lexicon_per_100_changed | floor) | \(.emphasis_ironic) | \(.dashes_added) | \(pct(.reworded; .changed)) | \(pct(.repeat_share; 1)) | \(.distinct_ratio * 100 | floor)% | \([.repeats[:6][] | "\(.term) ×\(.runs)"] | join(", ")) |"' "$f"
done <"$rows"
