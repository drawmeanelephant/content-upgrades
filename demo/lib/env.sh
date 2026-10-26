# Sourced (hidden) at the top of every beat tape, from the repo root:
#
#   Type "source demo/lib/env.sh"
#
# Gives each take a fresh scratch workdir with short on-screen paths,
# the pinned engines, a private artifact store, the mock backend, and a
# fixed prompt, so every retake prints the same thing.

DEMO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

# Pinned engines unless the caller (Makefile / scripts/engines.sh) already set them.
export KNAP_K4O_PATH="${KNAP_K4O_PATH:-$HOME/.cache/knap-engines/k4o-f97c5db/k4o}"
export KNAP_DOGBED_PATH="${KNAP_DOGBED_PATH:-$HOME/.cache/knap-engines/dogbed-0c94175/dogbed}"
export KNAP_BACKEND=mock
export PATH="$DEMO_ROOT/knap-mcp/zig-out/bin:$PATH"
export TZ=UTC LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
export PAGER="less -R"
unset JQ_COLORS

# Scratch workdir: symlinks keep on-screen paths short (data/, templates/)
# and keep rendered output out of the repo.
DEMO_WORK=$(mktemp -d "${TMPDIR:-/tmp}/knap-demo.XXXXXX")
export DEMO_WORK
for d in data templates eval src; do ln -s "$DEMO_ROOT/knap-mcp/$d" "$DEMO_WORK/$d"; done
ln -s "$DEMO_ROOT/demo/fixtures" "$DEMO_WORK/fixtures"
export KNAP_MCP_HOME="$DEMO_WORK/.knap-mcp"
# rm -r removes the symlinks themselves, never their targets.
trap 'rm -rf "$DEMO_WORK"' EXIT
cd "$DEMO_WORK" || return

glow() { command glow --config "$DEMO_ROOT/demo/lib/glow.yml" "$@"; }

# seeded/<template>.knap: the shipped template with its first
# `{% endif %}` line removed (the eval corpus's unclosed-if class).
# Derived at take time so it tracks template edits.
demo_seed_unclosed_if() {
  local id=${1:-verdict}
  mkdir -p seeded
  awk 'BEGIN{done=0} !done && /^\{% endif %\}$/ {done=1; next} {print}' \
    "templates/$id.knap" > "seeded/$id.knap"
}

# Full-screen slate for beats whose feature has not landed yet, so the
# rough cut keeps the beat's slot and timing.
demo_slate() {
  local beat=$1 title=$2 status=$3 line=$4
  clear
  printf '\n\n\n\n\n\n\n\n'
  printf '        \e[38;5;245mBEAT %s\e[0m\n\n' "$beat"
  printf '        \e[1;38;5;141m%s\e[0m\n\n' "$title"
  printf '        %s\n\n' "$line"
  printf '        \e[38;5;215mplaceholder: %s\e[0m\n' "$status"
  # Hold the slate with no prompt or cursor until vhs stops recording.
  printf '\e[?25l'
  read -r -s -n 1 || true
  printf '\e[?25h'
}

PS1='\[\e[38;5;141m\]demo\[\e[0m\] \$ '

demo_ok=1
for bin in knap-mcp jq glow; do
  command -v "$bin" >/dev/null 2>&1 || { printf 'demo env: %s not on PATH\n' "$bin"; demo_ok=0; }
done
for eng in "$KNAP_K4O_PATH" "$KNAP_DOGBED_PATH"; do
  [ -x "$eng" ] || { printf 'demo env: engine missing: %s\n' "$eng"; demo_ok=0; }
done
# Leave errors on screen so a broken take is obvious in the render.
[ "$demo_ok" = 1 ] && clear
unset demo_ok bin eng d
