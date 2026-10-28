#!/bin/sh
# Install a pinned boris binary by building it from source.
#
#   scripts/install-boris.sh [<tag> [<zig-version> [<dest>]]]
#
#   tag          git tag in drawmeanelephant/boris (default v0.8.2: the
#                version boris-site/ and knap_publish_check were measured
#                against — see docs/tracks/B1.md; the default is checked
#                against BORIS_COMMIT, other tags are not pinned)
#   zig-version  toolchain for the build (default 0.16.0; boris migrated to
#                Zig 0.17.0 after v0.8.2, so the tag does not build on the
#                0.17.0 toolchain this repo pins)
#   dest         binary path to write
#                (default ~/.cache/knap-boris/<tag>/boris)
#
# boris ships no prebuilt release binaries — the tags are source releases —
# so this clones the tag shallow and runs `zig build`. A tag is movable, so
# the default tag's HEAD is checked against the pinned BORIS_COMMIT after
# the clone. The Zig toolchain URL comes from ziglang.org's index.json but
# the sha256 is verified against the pin table below — a hash read from the
# same fetch as the URL proves nothing. Idempotent: an existing executable
# <dest> is kept (this is what makes it cheap under an actions/cache
# restore).
#
# Needs: jq, git, curl, tar + xz, and sha256sum or shasum.
set -eu

# Source pins; bump deliberately, in their own change. BORIS_COMMIT is the
# peeled commit DEFAULT_TAG must resolve to
# (git ls-remote https://github.com/drawmeanelephant/boris 'refs/tags/v0.8.2^{}')
# — the tag itself is movable and proves nothing on its own.
DEFAULT_TAG=v0.8.2
BORIS_COMMIT=294f71f9cec73508bf388c4367fce4366b37469d
DEFAULT_ZIGV=0.16.0

# Pinned sha256 of the zig $DEFAULT_ZIGV tarball per supported target, from
# ziglang.org/download/index.json at pin time. The live index fetch below is
# trusted only for the tarball URL.
pinned_zig_shasum() {
    case $1 in
    x86_64-linux)  echo 70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00 ;;
    aarch64-linux) echo ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17 ;;
    aarch64-macos) echo b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489 ;;
    x86_64-macos)  echo 0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7 ;;
    *) return 1 ;;
    esac
}

TAG=${1:-$DEFAULT_TAG}
ZIGV=${2:-$DEFAULT_ZIGV}
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
[ -n "$tarball" ] || die "zig $ZIGV has no $ztarget build in the download index"

# The sha256 comes from the pin table whenever it covers this version and
# target; otherwise fall back to the index shasum with a warning.
if [ "$ZIGV" = "$DEFAULT_ZIGV" ] && shasum=$(pinned_zig_shasum "$ztarget"); then
    :
else
    shasum=$(jq -r --arg v "$ZIGV" --arg t "$ztarget" '.[$v][$t].shasum // empty' "$WORK/index.json")
    echo "install-boris: warning: zig $ZIGV/$ztarget not in the shasum pin table; trusting index.json" >&2
fi
[ -n "$shasum" ] || die "zig $ZIGV $ztarget: no shasum available"

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
if [ "$TAG" = "$DEFAULT_TAG" ]; then
    got=$(git -C "$WORK/src" rev-parse HEAD)
    [ "$got" = "$BORIS_COMMIT" ] ||
        die "boris $TAG resolved to $got, expected pinned $BORIS_COMMIT (tag moved?)"
else
    echo "install-boris: warning: non-default tag $TAG; skipping BORIS_COMMIT pin check" >&2
fi

echo "install-boris: building boris $TAG with zig $ZIGV (-Doptimize=ReleaseSafe -Dcpu=baseline)"
(cd "$WORK/src" && "$ZIG" build -Doptimize=ReleaseSafe -Dcpu=baseline)
[ -x "$WORK/src/zig-out/bin/boris" ] || die "build produced no zig-out/bin/boris"

mkdir -p "$(dirname "$DEST")"
cp "$WORK/src/zig-out/bin/boris" "$DEST"
echo "install-boris: $("$DEST" --version 2>/dev/null || echo boris) -> $DEST"
