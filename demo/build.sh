#!/usr/bin/env bash
# Demo video pipeline: vhs tapes -> mp4 clips -> ffmpeg trim/concat.
#
#   demo/build.sh [smoke]          smoke test on dummy content -> demo/out/smoke.mp4
#   demo/build.sh check            dependency check (video tools, engines, knap-mcp build)
#   demo/build.sh tapes [NN ...]   render beat tapes, all or by number -> demo/out/tapes/
#   demo/build.sh rough [NN ...]   normalize + concat rendered beats -> demo/out/rough-cut.mp4
#
# Tapes run from the repo root (their Output/Source paths are repo-relative).
# Rendered media lives in demo/out/, which is gitignored.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DEMO="$ROOT/demo"
OUT="$DEMO/out"

# Mezzanine format: every clip is re-encoded to this before concat, and the
# Kdenlive project profile should match it. vhs 0.12 writes 25 fps mp4 no
# matter what `Set Framerate` says, so normalizing is required, not cosmetic.
WIDTH=1920
HEIGHT=1080
FPS=30

export KNAP_K4O_PATH="${KNAP_K4O_PATH:-$HOME/.cache/knap-engines/k4o-f97c5db/k4o}"
export KNAP_DOGBED_PATH="${KNAP_DOGBED_PATH:-$HOME/.cache/knap-engines/dogbed-0c94175/dogbed}"

log() { printf '==> %s\n' "$*"; }
die() { printf 'demo/build.sh: %s\n' "$*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing '$1' (install: $2)"
}

check_video() {
  need vhs "brew install vhs"
  need ttyd "brew install ttyd"
  need ffmpeg "brew install ffmpeg"
  need ffprobe "brew install ffmpeg"
  # vhs drives a headless Chrome through go-rod. With no local Chrome or
  # Chromium, go-rod downloads one into ~/.cache/rod on the first run.
  local browser="none found (vhs downloads Chromium into ~/.cache/rod on first run)"
  if [ -d "/Applications/Google Chrome.app" ] || [ -d "/Applications/Chromium.app" ] ||
    command -v chromium >/dev/null 2>&1 || command -v google-chrome >/dev/null 2>&1; then
    browser=found
  fi
  log "vhs $(vhs --version | awk '{print $3}'), ttyd $(ttyd --version | awk '{print $3}'), ffmpeg $(ffmpeg -version | awk 'NR==1{print $3}'), browser: $browser"
}

check_beats() {
  need jq "brew install jq"
  need glow "brew install glow"
  need zig "Zig 0.17.0 from ziglang.org"
  [ -x "$KNAP_K4O_PATH" ] || die "k4o engine not found at $KNAP_K4O_PATH"
  [ -x "$KNAP_DOGBED_PATH" ] || die "dogbed engine not found at $KNAP_DOGBED_PATH"
  log "building knap-mcp"
  (cd "$ROOT/knap-mcp" && zig build)
  log "engines: k4o=$KNAP_K4O_PATH dogbed=$KNAP_DOGBED_PATH"
}

duration() {
  ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1"
}

# render <repo-relative tape>: run vhs from the repo root, log to demo/out/logs.
render() {
  local tape=$1 name logf
  name=$(basename "$tape" .tape)
  mkdir -p "$OUT/logs"
  logf="$OUT/logs/$name.log"
  log "vhs $tape"
  if ! (cd "$ROOT" && vhs "$tape") >"$logf" 2>&1; then
    tail -20 "$logf" >&2
    die "vhs failed on $tape (log: $logf)"
  fi
}

# normalize <in> <out> [start] [length]: re-encode to the mezzanine format,
# optionally trimming. Re-encoding makes cuts frame-accurate and every clip
# concat-compatible.
normalize() {
  local in=$1 out=$2 start=${3:-} length=${4:-}
  local args=()
  if [ -n "$start" ]; then args+=(-ss "$start"); fi
  args+=(-i "$in")
  if [ -n "$length" ]; then args+=(-t "$length"); fi
  ffmpeg -v error -y "${args[@]}" \
    -vf "fps=$FPS,scale=$WIDTH:$HEIGHT:force_original_aspect_ratio=decrease,pad=$WIDTH:$HEIGHT:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p" \
    -c:v libx264 -preset medium -crf 18 -an "$out"
}

# concat <out> <clip>...: stream-copy join; clips must already be normalized.
concat() {
  local out=$1 list c
  shift
  list="$(dirname "$out")/.$(basename "$out" .mp4).concat.txt"
  : >"$list"
  for c in "$@"; do printf "file '%s'\n" "$c" >>"$list"; done
  ffmpeg -v error -y -f concat -safe 0 -i "$list" -c copy -movflags +faststart "$out"
}

# verify <file>: decode every frame; any decode error fails the build.
verify() {
  local errs
  errs=$(ffmpeg -v error -i "$1" -f null - 2>&1) || die "$1 does not decode: $errs"
  [ -z "$errs" ] || die "$1 decoded with errors: $errs"
}

describe() {
  printf '%s, %ss' \
    "$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,r_frame_rate,pix_fmt -of csv=p=0 "$1")" \
    "$(duration "$1")"
}

# select <dir> <ext> [NN ...]: numbered files in dir, minus 00-smoke,
# filtered to the given beat numbers (04 matches 04-*, 04b matches 04b-*).
select_files() {
  local dir=$1 ext=$2 f n want
  shift 2
  for f in "$dir"/[0-9]*."$ext"; do
    [ -e "$f" ] || continue
    n=$(basename "$f")
    case "$n" in 00-*) continue ;; esac
    if [ $# -eq 0 ]; then
      echo "$f"
      continue
    fi
    for want in "$@"; do
      case "$n" in "$want"-*)
        echo "$f"
        break
        ;;
      esac
    done
  done
}

cmd_smoke() {
  check_video
  render demo/tapes/00-smoke.tape
  local raw="$OUT/smoke/raw.mp4" d a_len b_start
  d=$(duration "$raw")
  # Keep the first 40% and the last 40%; the middle 20% stands in for dead air.
  a_len=$(awk -v d="$d" 'BEGIN{printf "%.3f", d*0.4}')
  b_start=$(awk -v d="$d" 'BEGIN{printf "%.3f", d*0.6}')
  log "raw take: $(describe "$raw")"
  log "trim: segment A [0, ${a_len}s) + segment B [${b_start}s, end)"
  normalize "$raw" "$OUT/smoke/a.mp4" 0 "$a_len"
  normalize "$raw" "$OUT/smoke/b.mp4" "$b_start"
  concat "$OUT/smoke.mp4" "$OUT/smoke/a.mp4" "$OUT/smoke/b.mp4"
  verify "$OUT/smoke.mp4"
  log "demo/out/smoke.mp4: $(describe "$OUT/smoke.mp4")"
}

report() {
  local t name mp4 target status got
  printf '\n%-22s %7s %9s  %s\n' tape target rendered status
  for t in "$@"; do
    name=$(basename "$t" .tape)
    mp4="$OUT/tapes/$name.mp4"
    target=$(sed -n 's/^# target: *//p' "$t" | head -1)
    status=$(sed -n 's/^# status: *//p' "$t" | head -1)
    got=-
    if [ -f "$mp4" ]; then got=$(printf '%.1fs' "$(duration "$mp4")"); fi
    printf '%-22s %7s %9s  %s\n' "$name" "$target" "$got" "$status"
  done
}

cmd_tapes() {
  check_video
  check_beats
  local tapes t
  tapes=$(select_files "$DEMO/tapes" tape "$@")
  [ -n "$tapes" ] || die "no tapes match: $*"
  for t in $tapes; do render "demo/tapes/$(basename "$t")"; done
  # shellcheck disable=SC2086
  report $tapes
}

cmd_rough() {
  check_video
  local clips=() c name
  mkdir -p "$OUT/rough"
  for c in $(select_files "$OUT/tapes" mp4 "$@"); do
    name=$(basename "$c")
    normalize "$c" "$OUT/rough/$name"
    clips+=("$OUT/rough/$name")
  done
  [ ${#clips[@]} -gt 0 ] || die "no rendered beats in demo/out/tapes (run: demo/build.sh tapes)"
  concat "$OUT/rough-cut.mp4" "${clips[@]}"
  verify "$OUT/rough-cut.mp4"
  log "demo/out/rough-cut.mp4: ${#clips[@]} clips, $(describe "$OUT/rough-cut.mp4")"
  log "timing reference only; the real cut is assembled in Kdenlive (docs/tracks/V0.md)"
}

case "${1:-smoke}" in
  smoke) cmd_smoke ;;
  check)
    check_video
    check_beats
    ;;
  tapes)
    shift
    cmd_tapes "$@"
    ;;
  rough)
    shift
    cmd_rough "$@"
    ;;
  -h | --help | help) sed -n '2,10p' "$0" ;;
  *) die "unknown command '$1' (smoke | check | tapes | rough)" ;;
esac
