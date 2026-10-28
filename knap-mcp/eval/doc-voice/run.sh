#!/usr/bin/env bash
# eval/doc-voice: the guarded doc-level voice pass (FILED-VOICE, #257).
#
#   knap-mcp/eval/doc-voice/run.sh     # exits 0 when every check passes
#
# record.md is a filed-style record; replies.jsonl holds three crafted
# replies that must be rejected (adds a block marker, edits a [[target]],
# drops an input **) and one that must pass. record.feral.md is the
# expected patched doc: the passing reply plus mock emphasis on two list
# items, and nothing else — verse lines, the include line, the Aside
# block, the fence and the quote are byte-identical.
#
# publish-check runs `boris validate` on a throwaway raw-profile site
# (boris-site's theme plus the link targets). Needs jq and boris
# (KNAP_BORIS_PATH or PATH); without boris the script fails, because a
# doc-voice run that can't run publish-check can't prove its invariants.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
bin="$root/zig-out/bin/knap-mcp"
[ -x "$bin" ] || (cd "$root" && zig build)
export KNAP_MCP_HOME="${KNAP_MCP_HOME:-$(mktemp -d)}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
site="$work/site"
mkdir -p "$site/content/mascots" "$site/content/limericks" "$site/content/aphorisms" "$site/content/snippets"
cp -R "$root/../boris-site/themes" "$site/"
printf '{"staging":"raw"}\n' >"$site/knap-site.json"
printf -- '---\ntitle: "Mascots"\nid: mascots\n---\n\nTrunk.\n' >"$site/content/mascots.md"
printf -- '---\ntitle: "Patchy"\nid: limericks/LIM-0001\n---\n\nA limerick.\n' >"$site/content/limericks/LIM-0001.md"
printf -- '---\ntitle: "Cassandra"\nid: aphorisms/APH-0001\n---\n\nAn aphorism.\n' >"$site/content/aphorisms/APH-0001.md"
printf -- 'Disclaimer text.\n' >"$site/content/snippets/disclaimer.md"
src="$site/content/mascots/990.doc-voice-fixture.md"
cp "$here/record.md" "$src"
export KNAP_BORIS_SITE="$site"
unset KNAP_BORIS_STAGING KNAP_BORIS_THEME KNAP_POLICY

fails=0
check() { # name, then a command that must succeed
    local name=$1
    shift
    if "$@" >/dev/null 2>&1; then printf 'ok    %s\n' "$name"; else printf 'FAIL  %s\n' "$name"; fails=$((fails + 1)); fi
}
refuses() { ! "$bin" doc-voice "$@"; }

common=(--tone feral --policy "$root/policy/filed.json" --replies "$here/replies.jsonl")
before=$(shasum -a 256 "$src")

"$bin" doc-voice "$src" "${common[@]}" --report "$work/report.json" >"$work/out.md"
r="$work/report.json"
check "dry-run output == record.feral.md" cmp "$work/out.md" "$here/record.feral.md"
check "report ok, publish-check ok (raw)" jq -e '.ok and .publish_check.ok and .publish_check.profile == "raw"' "$r"
check "invariants: structhash, frontmatter, links, atoms" jq -e '.structhash_equal and .frontmatter_equal and .links_equal and .atoms_equal' "$r"
check "density does not drop" jq -e '.density_after >= .density_before' "$r"
check "3 guard rejections, accounted per paragraph" jq -e '[.guard_rejections[].para] == [1,2,3] and ([.fields[] | select(.status == "rejected")] | length) == 3' "$r"
check "rejection: block marker" jq -e '.guard_rejections[0].reason | contains("starts with a block marker")' "$r"
check "rejection: edited [[target]]" jq -e '.guard_rejections[1].reason | contains("drops wikilink [[limericks/LIM-0001|Patchy]]")' "$r"
check "rejection: dropped **" jq -e '.guard_rejections[2].reason | contains("drops markup character *")' "$r"
check "rejected paragraphs survive verbatim" jq -e 'all(.fields[] | select(.status == "rejected"); .before == .after)' "$r"
check "verse + label line groups skipped (3)" jq -e '.line_groups_skipped == 3' "$r"
check "verse lines untouched" bash -c "diff <(grep '  \$' '$here/record.md') <(grep '  \$' '$work/out.md')"
check "include/aside/fence/quote untouched" bash -c "for p in '{{include' '<Aside' 'aside paragraph' 'fenced paragraph' '> “Nothing'; do diff <(grep -F \"\$p\" '$here/record.md') <(grep -F \"\$p\" '$work/out.md') || exit 1; done"
check "structhash --ignore-formatting equal (CLI)" bash -c "[ \"\$('$bin' structhash --ignore-formatting '$here/record.md' | cut -c1-16)\" = \"\$('$bin' structhash --ignore-formatting '$work/out.md' | cut -c1-16)\" ]"

check "--apply without --out refuses" refuses "$src" "${common[@]}" --apply
check "--out without --apply refuses" refuses "$src" "${common[@]}" --out "$work/x.md"
check "--apply --out into content/ refuses" refuses "$src" "${common[@]}" --apply --out "$site/content/mascots/x.md"
check "--apply --out over the source refuses" refuses "$src" "${common[@]}" --apply --out "$work/site/content/../content/mascots/990.doc-voice-fixture.md"
check "no policy refuses" bash -c "cd '$work' && ! '$bin' doc-voice '$src' --tone feral"
"$bin" doc-voice "$src" "${common[@]}" --apply --out "$work/applied.md" >"$work/apply.json"
check "--apply --out writes the patched doc" cmp "$work/applied.md" "$here/record.feral.md"
check "source never written" bash -c "[ \"\$(shasum -a 256 '$src')\" = '$before' ]"

cp "$here/record.md" "$site/content/limericks/LIM-0990.md"
"$bin" doc-voice "$site/content/limericks/LIM-0990.md" "${common[@]}" >"$work/denied.json"
check "policy-denied collection: no rewrites, no calls" jq -e '.ok and .paragraphs_rewritten == 0 and .policy.paragraphs == false and (.publish_check.skipped | contains("denies"))' "$work/denied.json"

if [ "$fails" -ne 0 ]; then
    printf '%d check(s) failed\n' "$fails"
    exit 1
fi
printf 'all doc-voice checks passed\n'
