#!/bin/sh
# Voice eval: same template, same data, three tones. Every tone must render
# with the original's structure hash, and every voiced doc must differ from
# the original as a string. Two negative controls inject layout through a
# value and must come out unequal. See README.md next to this script.
#
#   knap-mcp/eval/voice/run.sh        exits 0 when every row passes
#
# Env: KNAP_MCP_BIN (default knap-mcp/zig-out/bin/knap-mcp, built if
# missing), KNAP_K4O_PATH / KNAP_DOGBED_PATH (default: the pins in
# scripts/engines.sh), KNAP_MCP_HOME (default: a fresh temp dir).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
knap=$(cd "$here/../.." && pwd)
root=$(cd "$knap/.." && pwd)
cd "$knap"

command -v jq >/dev/null 2>&1 || { echo "voice-eval: needs jq" >&2; exit 1; }
if [ -z "${KNAP_K4O_PATH:-}" ] || [ -z "${KNAP_DOGBED_PATH:-}" ]; then
    eval "$("$root/scripts/engines.sh" env)"
fi
export KNAP_K4O_PATH KNAP_DOGBED_PATH
if [ -z "${KNAP_MCP_HOME:-}" ]; then
    KNAP_MCP_HOME=$(mktemp -d)
fi
export KNAP_MCP_HOME

bin=${KNAP_MCP_BIN:-$knap/zig-out/bin/knap-mcp}
if [ ! -x "$bin" ]; then
    (cd "$knap" && zig build) || { echo "voice-eval: zig build failed" >&2; exit 1; }
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

templates="verdict apparatus release-notes reading-note"
targets="markdown html"
tones="mild spicy feral"
failed=0
has_voice=no
"$bin" --help 2>/dev/null | grep -q '^  knap-mcp voice' && has_voice=yes
voice_checked=0

note() { echo "voice-eval: $*" >&2; }

# render <template> <data> <target> <out>: 0 when the engine rendered.
render() {
    if ! "$bin" render "$1" -d "$2" --target "$3" --out "$4" >"$work/render.json" 2>"$work/render.err" ||
        ! jq -e '.ok == true' "$work/render.json" >/dev/null 2>&1 || [ ! -f "$4" ]; then
        note "render $1 --target $3 failed: $(cat "$work/render.err" "$work/render.json" 2>/dev/null | tr '\n' ' ')"
        return 1
    fi
}

shash() {
    "$bin" structhash "$1" --target "$2" | cut -d' ' -f1
}

# Number of string leaves whose value differs between two data files.
changed() {
    jq -n --slurpfile a "$1" --slurpfile b "$2" '
        $a[0] as $o | $b[0] as $v
        | [ $o | paths(type == "string") ]
        | map(. as $p | select(($o | getpath($p)) != ($v | try getpath($p) catch null))) | length'
}

# --- voiced data: jq reference, cross-checked against `knap-mcp voice` ------

for t in $templates; do
    data=data/$t.sample.json
    for tone in $tones; do
        mock=prompts/voice/mock/$tone.jsonl
        jq --arg template "$t" --slurpfile mock "$mock" -f "$here/apply-mock.jq" "$data" >"$work/$t.$tone.json"
        jq --arg template "$t" --arg mode report --slurpfile mock "$mock" -f "$here/apply-mock.jq" "$data" >"$work/$t.$tone.report"
        missed=$(jq -r '.missed | join(", ")' "$work/$t.$tone.report")
        [ -n "$missed" ] && note "warning: $tone mock lines for $t do not match the sample data: $missed"
        if [ "$has_voice" = yes ]; then
            if "$bin" voice "$t" -d "$data" --tone "$tone" --backend mock >"$work/voice.json" 2>"$work/voice.err" &&
                jq -S '.data' "$work/voice.json" >"$work/voice.data" 2>/dev/null &&
                jq -S . "$work/$t.$tone.json" | cmp -s - "$work/voice.data"; then
                voice_checked=$((voice_checked + 1))
                grep '^calls: ' "$work/voice.err" | sed "s/^/  $t $tone: /" >>"$work/counters"
            else
                note "FAIL: knap-mcp voice $t --tone $tone differs from the jq reference: $(head -c 400 "$work/voice.err")"
                failed=1
            fi
        fi
    done
done

# --- the table ----------------------------------------------------------------

echo "voice eval: k4o $(basename "$(dirname "$KNAP_K4O_PATH")"), dogbed $(basename "$(dirname "$KNAP_DOGBED_PATH")")"
echo
echo "| template | target | orig | mild | spicy | feral | equal | strings differ | fields changed |"
echo "|---|---|---|---|---|---|---|---|---|"
for t in $templates; do
    lines=0
    covered=0
    fields=""
    for tone in $tones; do
        n=$(jq .lines "$work/$t.$tone.report")
        lines=$((lines + n))
        [ "$(jq .applied "$work/$t.$tone.report")" -gt 0 ] && covered=$((covered + 1))
        fields="$fields${fields:+/}$(changed "data/$t.sample.json" "$work/$t.$tone.json")"
    done
    for tg in $targets; do
        if ! render "$t" "data/$t.sample.json" "$tg" "$work/$t.orig.$tg"; then
            echo "| $t | $tg | render failed | | | | NO | | $fields |"
            failed=1
            continue
        fi
        orig=$(shash "$work/$t.orig.$tg" "$tg")
        row="| $t | $tg | $orig"
        equal=yes
        differ=yes
        for tone in $tones; do
            out="$work/$t.$tone.$tg"
            if ! render "$t" "$work/$t.$tone.json" "$tg" "$out"; then
                row="$row | render failed"
                equal=NO
                continue
            fi
            h=$(shash "$out" "$tg")
            row="$row | $h"
            [ "$h" = "$orig" ] || equal=NO
            cmp -s "$out" "$work/$t.orig.$tg" && differ=NO
        done
        if [ "$covered" -eq 0 ]; then
            differ="no mock coverage"
            [ "$lines" -gt 0 ] && { differ="stale mock"; failed=1; }
        elif [ "$covered" -lt 3 ]; then
            differ="partial mock coverage"
            failed=1
        fi
        [ "$equal" = yes ] || failed=1
        [ "$differ" = NO ] && failed=1
        echo "$row | $equal | $differ | $fields |"
    done
done

# --- negative controls: layout injected through a value must move the hash ---

echo
echo "| negative control | target | orig | drifted | equal | result |"
echo "|---|---|---|---|---|---|"
jq '.take = "the **boring** database that actually ships"' data/verdict.sample.json >"$work/neg.markup.json"
jq '.take = "the boring database\n- that actually ships"' data/verdict.sample.json >"$work/neg.newline-list.json"
jq '.summary |= gsub("durable"; "**durable**")' data/verdict.sample.json >"$work/neg.strip-src.json"
jq . data/verdict.sample.json >"$work/neg.strip-markup.json"
for neg in markup newline-list strip-markup; do
    ctl_field=take
    [ "$neg" = strip-markup ] && ctl_field=summary
    for tg in $targets; do
        if [ "$neg" = strip-markup ]; then
            # The source carries `**`; the drifted value drops it. Removal
            # must move the hash as surely as injection.
            if ! render verdict "$work/neg.strip-src.json" "$tg" "$work/neg.strip-src.$tg"; then
                echo "| verdict $ctl_field: $neg | $tg | render failed | | | FAIL |"
                failed=1
                continue
            fi
            orig=$(shash "$work/neg.strip-src.$tg" "$tg")
        else
            orig=$(shash "$work/verdict.orig.$tg" "$tg")
        fi
        if ! render verdict "$work/neg.$neg.json" "$tg" "$work/neg.$neg.$tg"; then
            echo "| verdict $ctl_field: $neg | $tg | $orig | render failed | | FAIL |"
            failed=1
            continue
        fi
        h=$(shash "$work/neg.$neg.$tg" "$tg")
        if [ "$h" = "$orig" ]; then
            echo "| verdict $ctl_field: $neg | $tg | $orig | $h | yes | FAIL (drift not caught) |"
            failed=1
        else
            echo "| verdict $ctl_field: $neg | $tg | $orig | $h | no | pass |"
        fi
    done
done

# --- guard controls: bad replies must be rejected, keeping the original ---

echo
echo "| guard control | expected | result |"
echo "|---|---|---|"

if [ "$has_voice" = yes ]; then
    mkdir -p "$work/prompts/voice/mock"
    cat >"$work/prompts/voice/mock/spicy.jsonl" <<'EOF'
{"template": "verdict", "field": "take", "field_role": "one-line hot take", "input": "the **boring** database that actually ships", "output": "the boring database that actually ships"}
{"template": "verdict", "field": "take", "field_role": "one-line hot take", "input": "the boring database that actually ships", "output": "Sure! Here is the take: the boring database that actually ships."}
{"template": "release-notes", "field": "breaking[0].fix", "field_role": "what to do about it, 1-3 sentences", "input": "Rename the key in acmedb.toml. 2.0 refuses to boot on the old name instead of quietly ignoring it, which is rude but correct.", "output": "Rename the key in acmedb.toml. 2.0 refuses to boot on the old name instead of quietly ignoring it, which is rude but correct!"}
EOF
    jq '.take = "the **boring** database that actually ships"' data/verdict.sample.json >"$work/ctl.markup-in.json"

    # expect_reject <data> <template> <field> <kept value> <reason substring>
    expect_reject() {
        KNAP_PROMPTS_DIR="$work/prompts" "$bin" voice "$2" -d "$1" --tone spicy --backend mock >"$work/ctl.out.json" 2>"$work/ctl.err" || return 1
        jq -e --arg f "$3" --arg v "$4" --arg r "$5" '
            .fields[] | select(.field == $f)
            | select(.status == "rejected" and .after == $v and (.reasons | join(" ") | contains($r)))' \
            "$work/ctl.out.json" | grep -q .
    }

    for ctl in "strip-markup|$work/ctl.markup-in.json|verdict|take|the **boring** database that actually ships|drops markup character" \
               "meta-prose-wrap|data/verdict.sample.json|verdict|take|the boring database that actually ships|wraps the input" \
               "footnote-bang|data/release-notes.sample.json|release-notes|breaking[0].fix|Rename the key in acmedb.toml. 2.0 refuses to boot on the old name instead of quietly ignoring it, which is rude but correct.|ends with !"; do
        name=${ctl%%|*}; rest=${ctl#*|}
        cdata=${rest%%|*}; rest=${rest#*|}
        ctpl=${rest%%|*}; rest=${rest#*|}
        cfield=${rest%%|*}; rest=${rest#*|}
        cvalue=${rest%%|*}; creason=${rest#*|}
        if expect_reject "$cdata" "$ctpl" "$cfield" "$cvalue" "$creason"; then
            echo "| $name | rejected, original kept | pass |"
        else
            echo "| $name | rejected, original kept | FAIL |"
            failed=1
        fi
    done
else
    echo "| (skipped: knap-mcp voice not built) | | |"
fi

if [ -f "$work/counters" ]; then
    echo
    echo "voice counters (knap-mcp voice --backend mock, per template x tone):"
    cat "$work/counters"
fi

echo
if [ "$has_voice" = yes ]; then
    echo "knap-mcp voice --backend mock matched the jq reference on $voice_checked template x tone runs."
else
    echo "knap-mcp voice is not built yet; voiced data is the jq reference (eval/voice/apply-mock.jq)."
fi
if [ "$failed" -ne 0 ]; then
    echo "voice eval: FAIL"
    exit 1
fi
echo "voice eval: pass"
