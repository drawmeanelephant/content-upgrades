#!/bin/sh
# Voice-tic sampling (VOICE-TICS, #382; filed.fyi#1061). Run a corpus of
# records through `doc-voice --dry-run` on each provider profile and prompt
# variant, then score every run with `knap-mcp voice-tics`: how often a
# rewrite adds a stock interjection, an ironic italic or a dash, and how
# much of what models add is the same handful of words.
#
#   knap-mcp/eval/voice-tics/run.sh [options] <profile>...
#
# Profiles: `mock` (mock emphasis, no model; the offline gate) or any name
# from scripts/providers.sh / $KNAP_PROVIDERS_LOCAL (see scripts/live.sh
# --list). Options:
#
#   --corpus filed|local  filed (default): eval/voice-tics/corpus.txt read
#                         from $KNAP_FILED_DIR (default ~/dev/filed.fyi) at
#                         the pinned commit. local: the in-repo fixtures.
#   --variant <v>         base (default; prompts/voice as shipped), a name
#                         under eval/voice-tics/variants/, or a dir. A
#                         variant is an overlay: only the files it changes.
#                         Repeat for an A/B.
#   --tone <t>            mild (default) | spicy | feral
#   --min-runs <n>        repeat threshold for voice-tics (default 3)
#   --out <dir>           results root (default ~/.cache/knap-voice-tics)
#
# Read the table with docs/tracks/VOICE-TICS.md: "tic runs" is the share of
# changed runs carrying a stock interjection or an ironic one-word italic;
# "density +" is the mean density gain, the reason the pass runs at all.
# Repeat share and distinct ratio grow with sample size: compare rows over
# the same corpus only.
#
# Per <profile>@<variant>, <out>/<profile>@<variant>/ gets one doc-voice
# report per record, doc-voice.err and profile.json. <out>/table.md is
# rebuilt from every profile.json under <out>, so parallel invocations
# sharing --out end with one table. Exit 1 when a profile resolves the
# wrong model, every call fails, or (mock) the scorer's invariants break.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
knap=$(cd "$here/../.." && pwd)
root=$(cd "$knap/.." && pwd)

die() { echo "voice-tics: $*" >&2; exit 1; }

corpus=filed tone=mild min_runs=3 variants='' profiles=''
out=${XDG_CACHE_HOME:-$HOME/.cache}/knap-voice-tics
while [ $# -gt 0 ]; do
    case $1 in
    --corpus) corpus=${2:?}; shift ;;
    --variant) variants="$variants ${2:?}"; shift ;;
    --tone) tone=${2:?}; shift ;;
    --min-runs) min_runs=${2:?}; shift ;;
    --out) out=${2:?}; shift ;;
    -h | --help) sed -n '2,/^set -eu/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option '$1' (see --help)" ;;
    *) profiles="$profiles $1" ;;
    esac
    shift
done
[ -n "$profiles" ] || die "name a profile (mock, or one from scripts/live.sh --list)"
variants=${variants:-base}
case $corpus in filed | local) ;; *) die "--corpus must be filed or local" ;; esac
case $out in /*) ;; *) out=$(pwd)/$out ;; esac
command -v jq >/dev/null 2>&1 || die "needs jq"

bin=${KNAP_MCP_BIN:-$knap/zig-out/bin/knap-mcp}
[ -x "$bin" ] || (cd "$knap" && zig build) || die "zig build failed"
policy=$knap/policy/filed.json

# Profiles in providers.sh read KNAP_ROOT and set `scratch`, which only
# live.sh uses.
# shellcheck disable=SC2034
KNAP_ROOT=$root
# shellcheck source=SCRIPTDIR/../../../scripts/providers.sh
. "$root/scripts/providers.sh"
local_file=${KNAP_PROVIDERS_LOCAL:-$HOME/.config/knap/providers.sh}
# shellcheck disable=SC1090
[ -f "$local_file" ] && . "$local_file"

# resolve <name>: set the profile's fields and env in this shell (live.sh).
resolve() {
    # shellcheck disable=SC2034
    backend='' label='' needs='' cmds='' expect='*' scratch=''
    if [ "$1" = mock ]; then
        backend=mock label='mock emphasis (no model)'
        return 0
    fi
    if command -v knap_profile_local >/dev/null 2>&1 && knap_profile_local "$1"; then return 0; fi
    knap_profile "$1"
}

missing() {
    m=
    for v in $needs; do
        eval "val=\${$v:-}"
        [ -n "$val" ] || m="$m $v"
    done
    for c in $cmds; do command -v "$c" >/dev/null 2>&1 || m="$m $c(command)"; done
    echo "${m# }"
}

# Corpus: <slug>.md plus a "slug as-path" list in a private dir; each
# result dir gets its own copy, so parallel runs sharing --out never race
# and a result dir can be re-scored on its own.
mkdir -p "$out"
src=$(mktemp -d)
trap 'rm -rf "$src"' EXIT
list=$src/list.txt
: >"$list"
if [ "$corpus" = local ]; then
    cp "$here/fixture.before.md" "$src/lorelog_LLG-9999-TIC.md"
    cp "$knap/eval/doc-voice/record.md" "$src/mascots_990.doc-voice-fixture.md"
    printf '%s\n' "lorelog_LLG-9999-TIC content/lorelog/LLG-9999-TIC.md" \
        "mascots_990.doc-voice-fixture content/mascots/990.doc-voice-fixture.md" >>"$list"
else
    filed=${KNAP_FILED_DIR:-$HOME/dev/filed.fyi}
    pin=$(sed -n 's/^# commit: *//p' "$here/corpus.txt")
    [ -n "$pin" ] || die "corpus.txt has no '# commit:' line"
    git -C "$filed" cat-file -e "$pin^{commit}" 2>/dev/null ||
        die "filed checkout $filed lacks commit $pin (set KNAP_FILED_DIR, or fetch it there)"
    grep -v '^#' "$here/corpus.txt" | while read -r path; do
        [ -n "$path" ] || continue
        slug=$(echo "${path#content/}" | sed 's|\.md$||; s|/|_|g')
        git -C "$filed" show "$pin:$path" >"$src/$slug.md" || die "cannot read $path at $pin"
        echo "$slug $path" >>"$list"
    done
fi

failed=0
for p in $profiles; do
    for v in $variants; do
        (
            resolve "$p" || die "unknown profile '$p' (see scripts/live.sh --list)"
            m=$(missing)
            [ -z "$m" ] || die "$p needs $m"
            vdir=''
            case $v in
            base) ;;
            */*) vdir=$v ;;
            *) vdir=$here/variants/$v ;;
            esac
            [ -z "$vdir" ] || [ -d "$vdir" ] || die "no variant dir $vdir"
            dir=$out/$p@$(basename "$v")
            rm -rf "$dir"
            mkdir -p "$dir/sources"
            cp "$src"/* "$dir/sources/"
            KNAP_MCP_HOME=$(mktemp -d)
            export KNAP_MCP_HOME
            KNAP_ACP_CWD=$KNAP_MCP_HOME
            # Tics need no publish-check: the frozen profile skips it
            # without running boris, and the report is written either way.
            KNAP_BORIS_STAGING=frozen
            export KNAP_ACP_CWD KNAP_BORIS_STAGING
            trap 'rm -rf "$KNAP_MCP_HOME"; [ -z "${KNAP_TMP_FILES:-}" ] || rm -f $KNAP_TMP_FILES' EXIT
            unset KNAP_DEBUG KNAP_PROMPTS_DIR
            if [ -n "$vdir" ]; then
                mkdir -p "$KNAP_MCP_HOME/prompts/voice"
                cp -R "$knap/prompts/voice/." "$KNAP_MCP_HOME/prompts/voice/"
                cp -R "$vdir/." "$KNAP_MCP_HOME/prompts/voice/"
                export KNAP_PROMPTS_DIR="$KNAP_MCP_HOME/prompts"
            fi
            model=-
            if [ "$backend" != mock ]; then
                probe=$("$bin" backends --probe 2>&1 || :)
                if [ "$backend" = acp ]; then
                    model=$(echo "$probe" | sed -n 's/^ *probe: model \([^ ,]*\).*/\1/p' | head -n 1)
                else
                    model=$(echo "$probe" | awk -v b="$backend" '$1 == b { print $2; exit }')
                fi
                # shellcheck disable=SC2254
                case ${model:-?} in $expect) ;; *) die "$p resolved model '${model:-?}', expected '$expect'" ;; esac
            fi
            echo "voice-tics: $p@$(basename "$v") ($label, model $model, tone $tone)" >&2
            t0=$(date +%s)
            pairs=
            while read -r slug as; do
                "$bin" doc-voice "$dir/sources/$slug.md" --as "$as" --tone "$tone" --policy "$policy" \
                    --backend "$backend" --report "$dir/$slug.report.json" </dev/null >/dev/null 2>>"$dir/doc-voice.err" || :
                if [ -s "$dir/$slug.report.json" ]; then
                    pairs="$pairs $dir/sources/$slug.md $dir/$slug.report.json"
                else
                    echo "  $slug: no report (see doc-voice.err)" >&2
                fi
            done <"$list"
            [ -n "$pairs" ] || die "$p: no doc-voice report"
            # shellcheck disable=SC2086
            "$bin" voice-tics --label "$label" --min-runs "$min_runs" $pairs >"$dir/scored.json"
            # density_gain: mean density_after - density_before per record,
            # the cost side of cutting tics (the filed batches chase a band).
            gain=$(jq -s 'map(.density_after - .density_before) | add / length' "$dir"/*.report.json)
            jq --arg profile "$p" --arg variant "$(basename "$v")" --arg model "$model" --arg tone "$tone" \
                --arg corpus "$corpus" --argjson secs "$(($(date +%s) - t0))" --argjson gain "$gain" \
                '{profile: $profile, variant: $variant, model: $model, tone: $tone, corpus: $corpus, seconds: $secs, density_gain: $gain} + .' \
                "$dir/scored.json" >"$dir/profile.json"
            rm -f "$dir/scored.json"
            jq -r '"  runs \(.runs), changed \(.changed), rejected \(.rejected) (\(.backend_errors) backend), tic runs \(.tic_runs), \(.seconds)s"' "$dir/profile.json" >&2
            if [ "$(jq '.changed == 0 and .backend_errors > 0' "$dir/profile.json")" = true ]; then
                die "$p: no call returned a reply (see backend errors in $dir/*.report.json)"
            fi
            # mock italicizes one existing word per run and adds no words:
            # anything else means the walk, the report or the scorer moved.
            if [ "$backend" = mock ]; then
                jq -e '.changed > 0 and .emphasis_on_existing == .changed and .emphasis_ironic == .changed and .lexicon_added == 0
                       and .added_words == 0 and .reworded == 0 and .rejected == 0' "$dir/profile.json" >/dev/null ||
                    die "mock profile broke the scorer's invariants: $(jq -c 'del(.lexicon, .emphasis, .repeats)' "$dir/profile.json")"
            fi
        ) || failed=1
    done
done

table=$out/table.md
{
    echo "| profile | variant | model | corpus | runs | changed | rejected | density + | tic runs | lexicon /100 | ironic italics | dashes | reworded | repeat share | distinct | top repeats |"
    echo "|---|---|---|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|---|"
    for f in "$out"/*@*/profile.json; do
        [ -f "$f" ] || continue
        jq -r 'def pct(n; d): if d == 0 then "-" else "\((100 * n / d) | floor)%" end;
            "| \(.profile) | \(.variant) | \(.model) | \(.corpus) | \(.runs) | \(.changed) | \(.rejected) | \(.density_gain // 0 | . * 10 | round / 10) | \(pct(.tic_runs; .changed)) | \(.lexicon_per_100_changed | floor) | \(.emphasis_ironic) | \(.dashes_added) | \(pct(.reworded; .changed)) | \(pct(.repeat_share; 1)) | \(.distinct_ratio * 100 | floor)% | \([.repeats[:5][] | "\(.term) ×\(.runs)"] | join(", ")) |"' "$f"
    done
} >"$table"
cat "$table"
echo "voice-tics: table in $table" >&2
exit "$failed"
