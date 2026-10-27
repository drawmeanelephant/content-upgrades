#!/usr/bin/env bash
# Beat-4 hero still: the verdict rendered to html by the pinned dogbed,
# wrapped in demo/hero/style.css, captured at 1920x1080 by headless Chrome.
#
#   demo/hero/build.sh    -> demo/hero/verdict.png
#
# "Zero JavaScript" is the pitch, so the wrapper is markup plus a stylesheet
# link only; the script greps the output and refuses to ship a page that
# contains any. Never touches the dogbed source tree.
set -euo pipefail

HERO=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERO/../.." && pwd)
KNAP=$ROOT/knap-mcp
BIN=$KNAP/zig-out/bin/knap-mcp

need() { command -v "$1" >/dev/null 2>&1 || { echo "hero/build.sh: missing '$1'" >&2; exit 1; }; }
need jq
need awk

: "${KNAP_K4O_PATH:=$("$ROOT/scripts/engines.sh" path k4o)}"
: "${KNAP_DOGBED_PATH:=$("$ROOT/scripts/engines.sh" path dogbed)}"
export KNAP_K4O_PATH KNAP_DOGBED_PATH KNAP_BACKEND=mock
[ -x "$KNAP_DOGBED_PATH" ] || { echo "hero/build.sh: dogbed pin missing (make engines)" >&2; exit 1; }
[ -x "$BIN" ] || (cd "$KNAP" && zig build) || { echo "hero/build.sh: zig build failed" >&2; exit 1; }

chrome=${KNAP_CHROME:-}
if [ -z "$chrome" ]; then
  for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    "/Applications/Chromium.app/Contents/MacOS/Chromium" \
    "$(command -v google-chrome || true)" "$(command -v chromium || true)"; do
    [ -n "$c" ] && [ -x "$c" ] && chrome=$c && break
  done
fi
[ -n "$chrome" ] || { echo "hero/build.sh: no Chrome/Chromium found" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/knap-hero.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export KNAP_MCP_HOME="$WORK/store"

"$BIN" render verdict -d "$KNAP/data/verdict.sample.json" \
  --target html --out "$WORK/fragment.html" | jq -c '{ok, target, bytes}'

# Wrap the fragment in a real page that links the demo stylesheet. The body
# class leaves room for the Muse Image art overlay (human, in Kdenlive): the
# still keeps the doc to one column on the left.
{
  printf '<!doctype html>\n<html lang="en">\n<head>\n'
  printf '<meta charset="utf-8">\n'
  printf '<title>Verdict: AcmeDB</title>\n'
  printf '<link rel="stylesheet" href="style.css">\n'
  printf '</head>\n<body>\n<main>\n'
  cat "$WORK/fragment.html"
  printf '</main>\n</body>\n</html>\n'
} > "$WORK/verdict.html"
cp "$HERO/style.css" "$WORK/style.css"

# No JavaScript in the output: no script tags, no inline handlers, no
# javascript: URLs. Fail loudly rather than ship a page that has any.
if grep -qiE '<script|on[a-z]+=|javascript:' "$WORK/verdict.html" "$WORK/style.css"; then
  echo "hero/build.sh: JavaScript found in the hero output; refusing" >&2
  exit 1
fi

profile=$(mktemp -d "${TMPDIR:-/tmp}/knap-hero-chrome.XXXXXX")
"$chrome" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --user-data-dir="$profile" --window-size=1920,1080 \
  --screenshot="$HERO/verdict.png" "file://$WORK/verdict.html" 2>/dev/null
rm -rf "$profile"
printf 'wrote %s (1920x1080)\n' "${HERO#"$ROOT"/}/verdict.png"
