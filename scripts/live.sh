#!/bin/sh
# Live provider runner: check a provider, then run the evals on it, and keep
# raw outputs plus provenance together. Profiles live in scripts/providers.sh.
#
#   scripts/live.sh --list                     every profile and its readiness
#   scripts/live.sh [options] <profile|all>... run suites on each profile
#
# Options:
#   --suite <s,...>  smoke (default) | repair | ratchet | voice | all
#   --full           repair also runs the 167-break eval/seeds.2nap.json
#   --out <dir>      results root (default ${XDG_CACHE_HOME:-~/.cache}/knap-live,
#                    outside the repo; pass --out knap-mcp/eval/results/live
#                    to update the committed record, see
#                    docs/tracks/LIVE-HYGIENE.md)
#   --force          keep going after a failed smoke
#
# `all` means every ready profile except `fake`. smoke always runs first: it
# resolves the model (an ACP handshake for agents, GET /models for HTTP) and
# stops the profile when the model doesn't match the profile's `expect`, or
# when any smoke row fails, before a long eval spends anything.
#
# Per profile, <out>/<profile>/ gets <suite>.out / .err, provenance.json and
# summary.txt. A rerun replaces only the suites it runs: earlier results for
# other suites, and their provenance entries, stay. Exit 1 when a named profile isn't
# ready, a smoke fails, the model mismatches, an eval has errored seeds, or
# voice moves the layout. ratchet-eval exits 1 whenever a live model misses
# the mock-tuned bar; that is recorded, not a failure here.
#
# Env: KNAP_MCP_BIN (default knap-mcp/zig-out/bin/knap-mcp, built if
# missing), KNAP_K4O_PATH / KNAP_DOGBED_PATH (default: the pins),
# KNAP_LIVE_VOICE_TEMPLATES (default verdict), KNAP_LIVE_VOICE_TONES
# (default "mild feral"), KNAP_PROVIDERS_LOCAL (private profiles).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
# Read by the profiles in providers.sh.
# shellcheck disable=SC2034
KNAP_ROOT=$root
knap=$root/knap-mcp
. "$root/scripts/providers.sh"
local_file=${KNAP_PROVIDERS_LOCAL:-$HOME/.config/knap/providers.sh}
KNAP_PROFILES_LOCAL=
# shellcheck disable=SC1090
[ -f "$local_file" ] && . "$local_file"

die() { echo "live: $*" >&2; exit 1; }

suites=smoke full=no force=no out='' list=no
profiles=
while [ $# -gt 0 ]; do
    case $1 in
    --list) list=yes ;;
    --suite) [ $# -ge 2 ] || die "--suite needs a value"; suites=$2; shift ;;
    --suite=*) suites=${1#--suite=} ;;
    --full) full=yes ;;
    --force) force=yes ;;
    --out) [ $# -ge 2 ] || die "--out needs a value"; out=$2; shift ;;
    --out=*) out=${1#--out=} ;;
    -h | --help) sed -n '2,/^set -eu/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option '$1' (see --help)" ;;
    *) profiles="$profiles $1" ;;
    esac
    shift
done
[ "$suites" = all ] && suites=smoke,repair,ratchet,voice
for s in $(echo "$suites" | tr ',' ' '); do
    case $s in smoke | repair | ratchet | voice) ;; *) die "unknown suite '$s'" ;; esac
done
case ,$suites, in *,smoke,*) ;; *) suites=smoke,$suites ;; esac

# resolve <name>: set the profile's fields and env in this shell.
resolve() {
    backend='' label='' needs='' cmds='' expect='*' scratch=''
    if command -v knap_profile_local >/dev/null 2>&1 && knap_profile_local "$1"; then
        source=local
        return 0
    fi
    source=scripts/providers.sh
    knap_profile "$1"
}

# missing: what the resolved profile still needs, or nothing.
missing() {
    m=
    for v in $needs; do
        eval "val=\${$v:-}"
        [ -n "$val" ] || m="$m $v"
    done
    for c in $cmds; do command -v "$c" >/dev/null 2>&1 || m="$m $c(command)"; done
    echo "${m# }"
}

all_profiles="$KNAP_PROFILES_LOCAL $KNAP_PROFILES"

if [ "$list" = yes ]; then
    printf '%-20s %-8s %-40s %s\n' profile backend status label
    for p in $all_profiles; do
        (
            resolve "$p" || exit 0
            m=$(missing)
            state=ready
            [ -z "$m" ] || state="needs $m"
            printf '%-20s %-8s %-40s %s\n' "$p" "$backend" "$state" "$label"
        )
    done
    exit 0
fi

[ -n "$profiles" ] || die "name a profile, or 'all' (see --list)"
expanded=
for p in $profiles; do
    if [ "$p" = all ]; then
        for q in $all_profiles; do
            [ "$q" = fake ] && continue
            (resolve "$q" && [ -z "$(missing)" ]) && expanded="$expanded $q"
        done
    else
        expanded="$expanded $p"
    fi
done
[ -n "$expanded" ] || die "no profile is ready (see --list)"

command -v jq >/dev/null 2>&1 || die "needs jq"
if [ -z "${KNAP_K4O_PATH:-}" ] || [ -z "${KNAP_DOGBED_PATH:-}" ]; then
    eval "$("$root/scripts/engines.sh" env)"
fi
export KNAP_K4O_PATH KNAP_DOGBED_PATH
bin=${KNAP_MCP_BIN:-$knap/zig-out/bin/knap-mcp}
if [ ! -x "$bin" ]; then
    (cd "$knap" && zig build) || die "zig build failed"
fi
out_given=$out
out=${out:-${XDG_CACHE_HOME:-$HOME/.cache}/knap-live}
case $out in /*) ;; *) out=$(pwd)/$out ;; esac

git_sha=$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)
git -C "$root" diff --quiet HEAD -- knap-mcp/src 2>/dev/null || git_sha="$git_sha+dirty"
version=$("$bin" --version | sed 's/^knap-mcp //')
pin() { basename "$(dirname "$1")"; }

summary=$(mktemp)
trap 'rm -f "$summary"' EXIT
status=0

# KNAP_DEBUG makes acp.zig inherit agent stderr and drops other internals
# into .err; suite() lands whatever a run prints into .err files (ignored
# under the committed record, not deleted), and agent stderr may carry
# account details. Debug knap-mcp itself with a direct invocation, not
# through this harness.
unset KNAP_DEBUG

# suite <name> <file-stem> <cmd...>: run one suite with stdout/stderr in
# $dir, record exit code and seconds.
suite() {
    name=$1 stem=$2
    shift 2
    if [ "$1" = "$bin" ]; then
        cmdline=$*
        cmdline=knap-mcp${cmdline#"$bin"}
    else
        # a shell function (voice_suite), not a knap-mcp argv: record a
        # readable name instead of mangling it into a fake command
        # ("knap-mcpvoice_suite").
        cmdline="$1 (shell function in scripts/live.sh)"
    fi
    t0=$(date +%s)
    set +e
    "$@" >"$dir/$stem.out" 2>"$dir/$stem.err"
    code=$?
    set -e
    secs=$(($(date +%s) - t0))
    jq -c --arg s "$name" --arg f "$stem" --arg cmd "$cmdline" --argjson c "$code" --argjson t "$secs" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '. + [{suite:$s, command:$cmd, exit:$c, seconds:$t, at:$at, out:($f+".out"), err:($f+".err")}]' \
        "$runs" >"$runs.tmp" && mv "$runs.tmp" "$runs"
    echo "  $stem: exit $code, ${secs}s" >&2
    return "$code"
}

# voice_suite (run through `suite`): voice each template's sample data per tone on the live
# backend, render original and voiced, and require equal normalized structure hashes
# (replies may insert inline formatting; --ignore-formatting is the proof).
voice_suite() {
    work=$KNAP_MCP_HOME/voice
    mkdir -p "$work"
    rm -f "$dir"/voice-*.json
    rows=0 same=0 failed=0
    echo "| template | tone | changed | rejected | fields | structhash |"
    echo "|---|---|--:|--:|--:|---|"
    for t in ${KNAP_LIVE_VOICE_TEMPLATES:-verdict}; do
        data=data/$t.sample.json
        "$bin" render "$t" -d "$data" --out "$work/$t.md" >/dev/null || { echo "| $t | - | - | - | - | render failed |"; failed=1; continue; }
        for tone in ${KNAP_LIVE_VOICE_TONES:-mild feral}; do
            rows=$((rows + 1))
            if ! "$bin" voice "$t" -d "$data" --tone "$tone" --backend "$backend" >"$work/$t.$tone.json"; then
                echo "| $t | $tone | - | - | - | voice failed |"
                failed=1
                continue
            fi
            cp "$work/$t.$tone.json" "$dir/voice-$t-$tone.json"
            jq '.data' "$work/$t.$tone.json" >"$work/$t.$tone.data.json"
            "$bin" render "$t" -d "$work/$t.$tone.data.json" --out "$work/$t.$tone.md" >/dev/null || { echo "| $t | $tone | - | - | - | render failed |"; failed=1; continue; }
            h0=$("$bin" structhash "$work/$t.md" --ignore-formatting | cut -d' ' -f1)
            h1=$("$bin" structhash "$work/$t.$tone.md" --ignore-formatting | cut -d' ' -f1)
            verdict=moved
            [ "$h0" = "$h1" ] && verdict=same && same=$((same + 1))
            [ "$verdict" = same ] || failed=1
            jq -r --arg t "$t" --arg tone "$tone" --arg v "$verdict" \
                '"| \($t) | \($tone) | \(.changed) | \([.fields[] | select(.status == "rejected")] | length) | \(.fields | length) | \($v) |"' \
                "$work/$t.$tone.json"
        done
    done
    echo
    echo "voice: $same/$rows layout-identical"
    return "$failed"
}

for p in $expanded; do
    if ! (resolve "$p"); then
        echo "live: unknown profile '$p' (see --list)" >&2
        status=1
        continue
    fi
    (
        resolve "$p"
        m=$(missing)
        if [ -n "$m" ]; then
            echo "live: skip $p: needs $m" >&2
            printf '%s\t%s\t-\t-\t-\t-\t-\t%s\n' "$p" "$backend" "skipped: needs $m" >>"$summary"
            exit 1
        fi
        dir_root=
        if [ "$scratch" = 1 ] && [ -z "$out_given" ]; then dir_root=$(mktemp -d); dir=$dir_root/$p; else dir=$out/$p; fi
        mkdir -p "$dir"
        KNAP_MCP_HOME=$(mktemp -d)
        export KNAP_MCP_HOME KNAP_ACP_CWD="$KNAP_MCP_HOME"
        # every mktemp above leaves with this subshell (previously they
        # leaked). Profiles register scratch files of their own (the droid
        # --settings json) in KNAP_TMP_FILES for the same cleanup.
        trap 'rm -rf "$KNAP_MCP_HOME" ${dir_root:+"$dir_root"}; [ -z "${KNAP_TMP_FILES:-}" ] || rm -f $KNAP_TMP_FILES' EXIT
        runs=$KNAP_MCP_HOME/runs.json
        echo '[]' >"$runs"
        cd "$knap"
        echo "live: $p ($label) -> $dir" >&2
        started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        failed=0

        suite smoke smoke "$bin" smoke --backend "$backend" || failed=1
        model=$(sed -n 's/^backend: .*   model: \(.*\)   effort: \(.*\)   served: .*/\1/p' "$dir/smoke.out")
        effort=$(sed -n 's/^backend: .*   model: .*   effort: \(.*\)   served: .*/\1/p' "$dir/smoke.out")
        note=
        if [ -z "$model" ]; then
            note="smoke did not resolve a model: $(tail -n 1 "$dir/smoke.err")"
            failed=1
        else
            # shellcheck disable=SC2254
            case $model in $expect) ;; *) note="model '$model' does not match expected '$expect'"; failed=1 ;; esac
        fi
        if [ -z "$note" ] && [ "$failed" = 1 ]; then
            note=$(awk -F'|' '$3 ~ /^ NO / { e = $(NF - 1); r = $2; gsub(/^ +| +$/, "", e); gsub(/ /, "", r); print "smoke " r ": " (e == "" ? "wrong shape" : e); exit }' "$dir/smoke.out")
            note=$(echo "$note" | sed 's/  */ /g')
        fi
        [ -n "$note" ] && echo "  $note" >&2
        go=yes
        [ "$failed" = 1 ] && [ "$force" = no ] && go=no
        [ -n "$note" ] && go=no

        if [ "$go" = yes ]; then
            for s in $(echo "$suites" | tr ',' ' '); do
                case $s in
                repair)
                    suite repair repair-seeds "$bin" eval --corpus eval/seeds.json --backend "$backend" || failed=1
                    if [ "$full" = yes ]; then
                        suite repair repair-seeds.2nap "$bin" eval --corpus eval/seeds.2nap.json --backend "$backend" || failed=1
                    fi
                    ;;
                ratchet) suite ratchet ratchet "$bin" ratchet-eval --corpus eval/ratchet.live.json --backend "$backend" || : ;;
                voice) suite voice voice voice_suite || failed=1 ;;
                esac
            done
        elif [ "$suites" != smoke ]; then
            echo "  stopping $p before the evals (--force to keep going)" >&2
        fi

        cell() { if [ -f "$dir/$1" ]; then sed -n "$2" "$dir/$1" | head -n 1; fi; }
        smoke_s=$(cell smoke.out 's/^smoke: \([0-9]*\/[0-9]*\) ok.*/\1 ok/p')
        repair_s=$(cell repair-seeds.out 's/^converged \([0-9]*\/[0-9]*\) breaks   mean iters \([0-9.]*\)   exact \([0-9]*\/[0-9]*\).*/\1 conv, \2 iters, \3 exact/p')
        full_s=$(cell repair-seeds.2nap.out 's/^converged \([0-9]*\/[0-9]*\) breaks   mean iters \([0-9.]*\)   exact \([0-9]*\/[0-9]*\).*/\1 conv, \2 iters, \3 exact/p')
        ratchet_s=
        [ -f "$dir/ratchet.out" ] && ratchet_s=$(awk -F'|' '
            $2 ~ /^ case / { for (i = 2; i < NF; i++) { h = $i; gsub(/ /, "", h); col[h] = i }; next }
            col["check"] && $2 !~ /^-/ && NF > 10 { n++; inert += $col["inert"]; if ($col["check"] ~ /^ ok/) ok++ }
            END { if (n) printf "%d/%d cases ok, inert %d", ok, n, inert }' "$dir/ratchet.out")
        voice_s=$(cell voice.out 's/^voice: //p')
        cat >"$dir/summary.txt" <<EOF
profile: $p
label:   $label
backend: $backend   model: ${model:-?}   effort: ${effort:-?}
smoke:   ${smoke_s:--}
repair:  ${repair_s:--}
repair (2nap): ${full_s:--}
ratchet: ${ratchet_s:--}
voice:   ${voice_s:--}
${note:+note:    $note}
EOF
        prev=$KNAP_MCP_HOME/prev.json
        if [ -f "$dir/provenance.json" ]; then jq '.runs // []' "$dir/provenance.json" >"$prev"; else echo '[]' >"$prev"; fi
        jq -n --arg profile "$p" --arg source "$source" --arg label "$label" --arg backend "$backend" \
            --arg model "$model" --arg effort "$effort" --arg expect "$expect" --arg note "$note" \
            --arg started "$started" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --arg git "$git_sha" --arg version "$version" --arg host "$(uname -sm)" \
            --arg k4o "$(pin "$KNAP_K4O_PATH")" --arg dogbed "$(pin "$KNAP_DOGBED_PATH")" \
            --slurpfile runs "$runs" --slurpfile old "$prev" '{
                profile: $profile, profile_source: $source, label: $label, backend: $backend,
                model: (if $model == "" then null else $model end),
                effort: (if $effort == "" or $effort == "-" then null else $effort end),
                expect: $expect, note: (if $note == "" then null else $note end),
                started: $started, finished: $finished,
                knap_mcp: {version: $version, git: $git}, engines: {k4o: $k4o, dogbed: $dogbed},
                host: $host,
                runs: ([$old[0][] | select(.out as $o | $runs[0] | map(.out) | index($o) | not)] + $runs[0])
            }' >"$dir/provenance.json"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$p" "$backend" "${model:-?}" "${smoke_s:--}" \
            "${repair_s:--}${full_s:+ | 2nap $full_s}" "${ratchet_s:--}" "${voice_s:--}" "${note:-}" >>"$summary"
        [ -z "$dir_root" ] || echo "live: $p scratch results in $dir_root (removed on exit; --out keeps them)" >&2
        exit "$failed"
    ) || status=1
done

echo
echo "| profile | backend | model | smoke | repair | ratchet | voice | note |"
echo "|---|---|---|---|---|---|---|---|"
while IFS='	' read -r a b c d e f g h; do
    echo "| $a | $b | ${c:--} | ${d:--} | ${e:--} | ${f:--} | ${g:--} | ${h:-} |"
done <"$summary"
exit "$status"
