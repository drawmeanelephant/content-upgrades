#!/bin/sh
# Install a pinned boris binary by building it from source.
#
#   scripts/install-boris.sh [<tag> [<zig-version> [<dest>]]]
#
#   tag          git tag in drawmeanelephant/boris (default v0.8.2: the
#                version boris-site/ and knap_publish_check were measured
#                against — see docs/tracks/B1.md)
#   zig-version  toolchain for the build (default 0.16.0; boris migrated to
#                Zig 0.17.0 after v0.8.2, so the tag does not build on the
#                0.17.0 toolchain this repo pins)
#   dest         binary path to write
#                (default ~/.cache/knap-boris/<tag>/boris)
#
# boris ships no prebuilt release binaries — the tags are source releases —
# so this clones the tag shallow and runs `zig build`. The Zig toolchain is
# resolved from ziglang.org's official index.json and sha256-verified before
# use. Idempotent: an existing executable <dest> is kept (this is what makes
# it cheap under an actions/cache restore).
#
# Needs: jq, git, curl, tar + xz, and sha256sum or shasum.
set -eu

TAG=${1:-v0.8.2}
ZIGV=${2:-0.16.0}
DEST=${3:-$HOME/.cache/knap-boris/$TAG/boris}

die() { echo "install-boris: $*" >&2; exit 1; }
for t in jq git curl tar xz; do
    command -v "$t" >/dev/null 2>&1 || die "missing '$t'"
done
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 ||
    die "missing sha256sum (or shasum)"

if [ -x "$DEST" ]; then
    echo "install-boris: keeping existing $DEST ($("$DEST" --version 2>/dev/null || echo '?'))"
    exit 0
fi

case "$(uname -s)-$(uname -m)" in
Linux-x86_64) ztarget=x86_64-linux ;;
Linux-aarch64) ztarget=aarch64-linux ;;
Darwin-arm64) ztarget=aarch64-macos ;;
Darwin-x86_64) ztarget=x86_64-macos ;;
*) die "no ziglang.org build for $(uname -s)-$(uname -m)" ;;
esac

WORK=$(mktemp -d "${TMPDIR:-/tmp}/install-boris.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

curl -fsSL https://ziglang.org/download/index.json -o "$WORK/index.json"
tarball=$(jq -r --arg v "$ZIGV" --arg t "$ztarget" '.[$v][$t].tarball // empty' "$WORK/index.json")
shasum=$(jq -r --arg v "$ZIGV" --arg t "$ztarget" '.[$v][$t].shasum // empty' "$WORK/index.json")
[ -n "$tarball" ] || die "zig $ZIGV has no $ztarget build in the download index"
[ -n "$shasum" ] || die "zig $ZIGV $ztarget: no shasum in the download index"

echo "install-boris: fetching zig $ZIGV ($ztarget)"
curl -fsSL "$tarball" -o "$WORK/zig.tar.xz"
if command -v sha256sum >/dev/null 2>&1; then
    echo "$shasum  $WORK/zig.tar.xz" | sha256sum -c -
else
    echo "$shasum  $WORK/zig.tar.xz" | shasum -a 256 -c -
fi
mkdir "$WORK/zig"
tar -xJf "$WORK/zig.tar.xz" -C "$WORK/zig" --strip-components 1
ZIG=$WORK/zig/zig
[ "$("$ZIG" version)" = "$ZIGV" ] || die "zig reports $("$ZIG" version), expected $ZIGV"

echo "install-boris: fetching drawmeanelephant/boris $TAG"
git clone -q --depth 1 --branch "$TAG" https://github.com/drawmeanelephant/boris "$WORK/src"

echo "install-boris: building boris $TAG with zig $ZIGV (-Doptimize=ReleaseSafe -Dcpu=baseline)"
(cd "$WORK/src" && "$ZIG" build -Doptimize=ReleaseSafe -Dcpu=baseline)
[ -x "$WORK/src/zig-out/bin/boris" ] || die "build produced no zig-out/bin/boris"

mkdir -p "$(dirname "$DEST")"
cp "$WORK/src/zig-out/bin/boris" "$DEST"
echo "install-boris: $("$DEST" --version 2>/dev/null || echo boris) -> $DEST"
