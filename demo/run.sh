#!/usr/bin/env bash
# End-to-end demo: every storyboard beat as one scripted terminal run on the
# mock backend. No vhs, no network, no live model calls; the video takes are
# demo/build.sh's job.
#
#   demo/run.sh            (or: make demo)
#
# The story: generic doc -> data -> repair -> render -> format_check ->
# density -> ratchet -> publish_check -> voice (mild/spicy/feral) -> one
# source, three targets -> numbers. Beat numbers follow demo/storyboard.md.
#
# Output (gitignored): $DEMO_OUT/transcript.txt, the normalized terminal
# transcript, and $DEMO_OUT/artifacts/, every file the beats write. doc ids
# and the scratch dir are normalized, so two runs on one commit print the
# same transcript; a rerun reports whether it matched the previous one.
#
# Env: DEMO_OUT (default demo/out/demo), KNAP_K4O_PATH / KNAP_DOGBED_PATH
# (default: the pins in scripts/engines.sh), KNAP_BORIS_PATH (default: boris
# on PATH; without it beat 5 is skipped and the summary says so).
# KNAP_MCP_HOME is always a fresh temp dir.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${DEMO_OUT:-$ROOT/demo/out/demo}
BIN_DIR=$ROOT/knap-mcp/zig-out/bin

die() { printf 'demo/run.sh: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "missing jq (brew install jq)"
: "${KNAP_K4O_PATH:=$("$ROOT/scripts/engines.sh" path k4o)}"
: "${KNAP_DOGBED_PATH:=$("$ROOT/scripts/engines.sh" path dogbed)}"
export KNAP_K4O_PATH KNAP_DOGBED_PATH
[ -x "$KNAP_K4O_PATH" ] || die "k4o engine not found at $KNAP_K4O_PATH (make engines)"
[ -x "$KNAP_DOGBED_PATH" ] || die "dogbed engine not found at $KNAP_DOGBED_PATH (make engines)"
[ -x "$BIN_DIR/knap-mcp" ] || (cd "$ROOT/knap-mcp" && zig build) || die "zig build failed"
BORIS=${KNAP_BORIS_PATH:-$(command -v boris || true)}

# Scratch workdir: symlinks keep on-screen paths short (data/, templates/),
# out/ points at the artifact dir. rm -r removes the links, not their targets.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/knap-demo.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
for d in data templates prompts eval src; do ln -s "$ROOT/knap-mcp/$d" "$WORK/$d"; done
ln -s "$ROOT/demo/fixtures" "$WORK/fixtures"
mkdir -p "$OUT"
[ -f "$OUT/transcript.txt" ] && mv "$OUT/transcript.txt" "$OUT/transcript.prev.txt"
rm -rf "$OUT/artifacts"
mkdir -p "$OUT/artifacts"
ln -s "$OUT/artifacts" "$WORK/out"

export PATH="$BIN_DIR:$PATH"
export KNAP_MCP_HOME="$WORK/.knap-mcp"
export KNAP_BACKEND=mock
export KNAP_PROMPTS_DIR="$ROOT/knap-mcp/prompts"
export KNAP_BORIS_SITE="$ROOT/boris-site"
[ -n "$BORIS" ] && export KNAP_BORIS_PATH="$BORIS"
export TZ=UTC LC_ALL=C
unset KNAP_TEMPLATES_DIR MODEL_API_KEY
cd "$WORK"

BEAT=setup
SUMMARY=()

close_beat() {
  [ "$BEAT" = setup ] || SUMMARY+=("$(printf '%-18s %-3s %s' "$BEAT_STATUS" "$BEAT" "$BEAT_TITLE")")
}
beat() {
  close_beat
  BEAT=$1 BEAT_TITLE=$2 BEAT_STATUS=ok
  printf '\n######## beat %s: %s\n\n' "$1" "$2"
}
say() { printf '# %s\n' "$*"; }
# fail: exit the beats subshell. Not set -e: beats runs on the left of `||`,
# where bash ignores -e. Loops in a command end in `|| exit 1` for the same
# reason; the subshell's EXIT trap names the beat.
fail() { printf 'demo: %s\n' "$*"; exit 1; }

# run [status]: print the command (read from stdin) as a prompt line, then
# run it. The command must exit with `status` (default 0) or the demo fails.
run() {
  local want=${1:-0} cmd rc=0
  cmd=$(cat)
  printf '$ %s\n' "$cmd"
  eval "$cmd" </dev/null || rc=$?
  [ "$rc" -eq "$want" ] || fail "exit $rc, expected $want"
  echo
}

# same_hash <file>: every structhash line in the file has one hash.
same_hash() {
  local n
  n=$(cut -d' ' -f1 "$1" | sort -u | awk 'END{print NR}')
  [ "$n" -eq 1 ] || fail "$n distinct layout hashes in $1"
  say "one layout hash across $(awk 'END{print NR}' "$1") renders"
  echo
}

beats() {
  trap '[ $? -eq 0 ] || printf "\ndemo: FAIL in beat %s\n" "$BEAT"' EXIT
  printf 'knap-mcp demo: backend mock, k4o %s, dogbed %s\n' \
    "$(basename "$(dirname "$KNAP_K4O_PATH")")" "$(basename "$(dirname "$KNAP_DOGBED_PATH")")"

  beat 1 "cold open: the generic AI doc"
  say "flat model output, verbatim (gpt-5-5-none via ACP): no callouts, footnotes, deep links or table"
  run <<'CMD'
head -12 fixtures/generic-ai-doc.md
CMD
  run <<'CMD'
knap-mcp density fixtures/generic-ai-doc.md | jq -c '{scorer, total, words}'
CMD

  beat 2 "ask for a verdict: the model drafts data only"
  say "the tools a model can call, straight from the MCP server over stdio"
  run <<'CMD'
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | knap-mcp | jq -r '[.result.tools[].name] | join(" ")'
CMD
  say "the model sees the shape, never the layout"
  run <<'CMD'
knap-mcp templates | jq -r '.templates[] | select(.id == "verdict") | .shape.fields | keys[]'
CMD
  say "the evidence store: ranked hits from the frozen boris artifact"
  run <<'CMD'
knap-mcp boris-ask 'AcmeDB backups' --limit 3 | jq -c '.results[] | {score, title}'
CMD
  run <<'CMD'
ln -s "$ROOT/demo/frozen" frozen
CMD
  run <<'CMD'
jq -r .label frozen/provenance.json
CMD
  say "the model's draft: values only, and it reaches its own verdict"
  run <<'CMD'
jq '{verdict, take, blockers}' frozen/02-verdict.drafted.json
CMD
  say "the model's draft validates against the shape (beat 4 renders the curated sample data, not this draft)"
  run <<'CMD'
knap-mcp validate verdict -d frozen/02-verdict.drafted.json | jq -c
CMD

  beat 3 "seeded failure -> diagnostic -> repair -> clean"
  say "seed: the shipped verdict template minus its first {% endif %}"
  run <<'CMD'
mkdir -p seeded && awk '!done && /^\{% endif %\}$/ {done=1; next} {print}' templates/verdict.knap > seeded/verdict.knap
CMD
  run 1 <<'CMD'
diff templates/verdict.knap seeded/verdict.knap
CMD
  run 1 <<'CMD'
KNAP_TEMPLATES_DIR=seeded knap-mcp validate verdict -d data/verdict.sample.json | jq -c '.diagnostics[0]'
CMD
  say "frozen live repair take (I5): Muse Wonder 1.0 via ACP (devin), converged in 1 iteration"
  run <<'CMD'
jq -c '{converged, iterations, step: .steps[0] | {line, detail, patch_applied}}' "$ROOT/demo/frozen/03-repair.json"
CMD
  say "the patch itself: what steps[0].patch changes in the seeded region"
  run <<'CMD'
jq -j '.steps[0].patch' "$ROOT/demo/frozen/03-repair.json" > out/repair.patch
CMD
  run 1 <<'CMD'
rs=$(jq -r '.steps[0].region_start' "$ROOT/demo/frozen/03-repair.json") && tail -n +$rs seeded/verdict.knap | diff - out/repair.patch
CMD
  run <<'CMD'
knap-mcp render verdict -d data/verdict.sample.json --target markdown --out out/verdict.md | jq -c '{ok, target, bytes}'
CMD
  run <<'CMD'
cmp "$ROOT/demo/frozen/03-repaired.md" out/verdict.md && echo "repaired doc is byte-identical to the clean render"
CMD

  beat 4 "the doc: render -> format_check -> density"
  run <<'CMD'
cat out/verdict.md
CMD
  run <<'CMD'
doc=$(knap-mcp render verdict -d data/verdict.sample.json --target markdown | jq -r .doc_id); echo "$doc"
CMD
  say "layer 2: advisory structure lint on the stored doc"
  run <<'CMD'
knap-mcp format-check "$doc" | jq -c
CMD
  run <<'CMD'
knap-mcp density "$doc" | jq -c '{scorer, total, words}'
CMD
  run <<'CMD'
knap-mcp density "$doc" | jq -r '.signals[] | select(.contribution != 0) | "\(.name)\t\(.contribution)"'
CMD

  beat 4b "density ratchet: values only, the template never changes"
  say "start from the required fields only"
  run <<'CMD'
jq -c 'keys' data/release-notes.min.json
CMD
  run <<'CMD'
knap-mcp ratchet release-notes -d data/release-notes.min.json --backend mock | tee out/ratchet.json | jq -c '.steps[] | {iteration, slot, gain, accepted, reason}'
CMD
  run <<'CMD'
jq -c '{stop, iterations, calls, score, slot_fill, rejections}' out/ratchet.json
CMD
  run <<'CMD'
knap-mcp density "$(jq -r .doc_id out/ratchet.json)" | jq -c '{scorer, total}'
CMD

  beat 5 "the boris catch: publish_check"
  if [ -z "$BORIS" ]; then
    say "SKIPPED: boris not on PATH (set KNAP_BORIS_PATH); publish_check needs it"
    BEAT_STATUS="SKIPPED (no boris)"
  else
    say "the real data plus one invented source"
    run <<'CMD'
jq '.sources |= .[:1] + [{name: "AcmeDB SOC 2 audit report", url: "https://example.com/acmedb/soc2", rel: "audit", reliability: "high", gaf: "high"}] + .[1:]' data/verdict.sample.json > out/verdict.hallucinated.json
CMD
    say "the template renders it without complaint: layout can't know a source is invented"
    run <<'CMD'
doc=$(knap-mcp render verdict -d out/verdict.hallucinated.json --out out/v1.md | jq -r .doc_id); echo "$doc"
CMD
    say "staged into a throwaway copy of the frozen boris site: the wiki-link has no target"
    run 1 <<'CMD'
knap-mcp publish-check "$doc" | jq -c '{ok, pages, links, diagnostics: [.diagnostics[] | {code, line, column, link}]}'
CMD
    run <<'CMD'
sed -n "$(knap-mcp publish-check "$doc" | jq -r '.diagnostics[0].line')p" out/v1.md
CMD
    say "the real sources resolve"
    run <<'CMD'
doc=$(knap-mcp render verdict -d data/verdict.sample.json --out out/v2.md | jq -r .doc_id); echo "$doc"
CMD
    run <<'CMD'
knap-mcp publish-check "$doc" | jq -c '{ok, pages, links, diagnostics}'
CMD
  fi

  beat 6 "same template, mild vs spicy vs feral"
  say "voice rewrites the voice: true values only, one backend call per value"
  run <<'CMD'
for t in mild spicy feral; do knap-mcp voice verdict -d data/verdict.sample.json --tone $t --backend mock | tee out/voice.$t.json | jq -c '{tone, changed, kept: [.fields[] | select(.status != "rewritten") | .field]}' || exit 1; done
CMD
  run <<'CMD'
jq -r '.fields[] | select(.status == "rewritten") | "\(.field): \(.after)"' out/voice.feral.json
CMD
  run <<'CMD'
for t in mild spicy feral; do jq .data out/voice.$t.json > out/verdict.$t.json || exit 1; done
CMD
  run <<'CMD'
for t in mild spicy feral; do for tg in markdown html; do knap-mcp render verdict -d out/verdict.$t.json --target $tg --out out/verdict.$t.${tg/markdown/md} | jq -c "{tone: \"$t\", ok, target, bytes}" || exit 1; done; done
CMD
  run <<'CMD'
knap-mcp render verdict -d data/verdict.sample.json --target html --out out/verdict.html | jq -c '{ok, target, bytes}'
CMD
  say "the falsifiable proof: the layout skeleton hash, text dropped"
  run <<'CMD'
knap-mcp structhash out/verdict.md out/verdict.mild.md out/verdict.spicy.md out/verdict.feral.md | tee out/structhash.md.txt
CMD
  same_hash out/structhash.md.txt
  run <<'CMD'
knap-mcp structhash out/verdict.html out/verdict.mild.html out/verdict.spicy.html out/verdict.feral.html | tee out/structhash.html.txt
CMD
  same_hash out/structhash.html.txt
  run 1 <<'CMD'
diff out/verdict.mild.md out/verdict.feral.md
CMD

  beat 7 "one source -> markdown + oliver + html"
  run <<'CMD'
knap-mcp render verdict -d data/verdict.sample.json --target markdown --out out/verdict.md | jq -c '{ok, target, bytes}'
CMD
  run <<'CMD'
oliver=$(knap-mcp render verdict -d data/verdict.sample.json --target oliver --out out/verdict.oliver | jq -r .doc_id); echo "$oliver"
CMD
  run <<'CMD'
knap-mcp format-check "$oliver" | jq -c
CMD
  run <<'CMD'
knap-mcp render verdict -d data/verdict.sample.json --target html --out out/verdict.html | jq -c '{ok, target, bytes}'
CMD
  run <<'CMD'
knap-mcp render apparatus -d data/apparatus.sample.json --target html --out out/apparatus.html | jq -c '{ok, target, bytes}'
CMD
  say "no script in any output (grep exits 1: zero matches everywhere)"
  run 1 <<'CMD'
grep -c '<script' out/verdict.md out/verdict.oliver out/verdict.html out/apparatus.html
CMD

  beat 8 "numbers, measured only (mock backend)"
  run <<'CMD'
knap-mcp eval --corpus eval/seeds.json --backend mock 2>/dev/null | grep '^converged'
CMD
  run <<'CMD'
knap-mcp eval --corpus eval/seeds.2nap.json --backend mock 2>/dev/null | grep '^converged'
CMD
  run <<'CMD'
find src/ -name '*.zig' -exec cat {} + | awk 'END{print NR " lines of Zig in src/"}'
CMD

  close_beat
  printf '\n######## summary\n\n'
  printf '%s\n' "${SUMMARY[@]}"
  printf '\nartifacts: %s/artifacts (%s files)\n' "${OUT#"$ROOT"/}" "$(find out/ -type f | awk 'END{print NR}')"
}

# Normalize what varies between runs: the scratch dir and doc id timestamps.
normalize() {
  awk -v work="$WORK" '{
    while ((i = index($0, work)) > 0) $0 = substr($0, 1, i - 1) "." substr($0, i + length(work))
    gsub(/doc-[0-9]+-[0-9]+/, "doc-<id>")
    print
    fflush()
  }'
}

rc=0
beats 2>&1 | normalize | tee "$OUT/transcript.txt" || rc=$?
echo
if [ "$rc" -ne 0 ]; then
  echo "demo: FAIL (transcript: $OUT/transcript.txt)"
  exit "$rc"
fi
if [ -f "$OUT/transcript.prev.txt" ]; then
  if cmp -s "$OUT/transcript.prev.txt" "$OUT/transcript.txt"; then
    echo "demo: transcript identical to the previous run"
  else
    echo "demo: transcript differs from the previous run (diff $OUT/transcript.prev.txt $OUT/transcript.txt)"
  fi
fi
echo "demo: ok (transcript: $OUT/transcript.txt)"
