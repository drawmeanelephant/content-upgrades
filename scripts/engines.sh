#!/bin/sh
# Pinned engine binaries for knap-mcp. A pin bump is a one-line change to
# the SHAs below, in its own PR.
#
#   scripts/engines.sh             build any missing pin
#   scripts/engines.sh env         print export lines for the pinned binaries
#   scripts/engines.sh path <name> print one pinned binary path (k4o|dogbed)
#
# Each pin lives in $KNAP_ENGINES_DIR/<name>-<sha7>/<name>. Builds run on a
# `git archive` export of $KNAP_ENGINES_SRC/<name> in a temp dir and are
# moved into place when done, so the source working trees are never touched
# and an existing pin dir is never rebuilt or overwritten.
set -eu

K4O_SHA=bdfb838a115e86483d9ef1f14d6768a9b9ea0754
DOGBED_SHA=d7ffaba102b8ad6f38bbe3343b24d9dade152a01

ENGINES_DIR=${KNAP_ENGINES_DIR:-$HOME/.cache/knap-engines}
SRC_DIR=${KNAP_ENGINES_SRC:-$HOME/dev}

pin_sha() {
    case "$1" in
    k4o) echo "$K4O_SHA" ;;
    dogbed) echo "$DOGBED_SHA" ;;
    *) echo "engines: unknown engine '$1' (k4o|dogbed)" >&2; exit 2 ;;
    esac
}

pin_dir() {
    sha=$(pin_sha "$1")
    echo "$ENGINES_DIR/$1-$(printf '%.7s' "$sha")"
}

build() {
    name=$1
    sha=$(pin_sha "$name")
    dest=$(pin_dir "$name")
    [ -x "$dest/$name" ] && return 0
    if [ -e "$dest" ]; then
        echo "engines: $dest exists but has no $name binary; inspect it by hand" >&2
        return 1
    fi
    repo=$SRC_DIR/$name
    if ! git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null; then
        echo "engines: commit $sha not found in $repo; fetch it there first" >&2
        return 1
    fi

    echo "engines: building $name at $sha"
    mkdir -p "$ENGINES_DIR"
    tmp=$(mktemp -d "$ENGINES_DIR/.build-$name.XXXXXX")
    mkdir "$tmp/src" "$tmp/out"
    if ! {
        git -C "$repo" archive --format=tar "$sha" | tar -x -C "$tmp/src" &&
            (cd "$tmp/src" && zig build -Doptimize=ReleaseSafe) &&
            cp "$tmp/src/zig-out/bin/$name" "$tmp/out/$name"
    }; then
        rm -rf "$tmp"
        echo "engines: $name build failed" >&2
        return 1
    fi
    echo "$name built from git archive $sha -Doptimize=ReleaseSafe" >"$tmp/out/PROVENANCE"
    if [ -e "$dest" ]; then
        echo "engines: $dest appeared during the build; keeping it"
    else
        mv "$tmp/out" "$dest"
        echo "engines: $name -> $dest/$name"
    fi
    rm -rf "$tmp"
}

case "${1:-build}" in
build)
    build k4o
    build dogbed
    ;;
env)
    k4o=$(pin_dir k4o)
    dogbed=$(pin_dir dogbed)
    echo "export KNAP_K4O_PATH=$k4o/k4o"
    echo "export KNAP_DOGBED_PATH=$dogbed/dogbed"
    ;;
path)
    name=${2:?usage: engines.sh path <k4o|dogbed>}
    dir=$(pin_dir "$name")
    echo "$dir/$name"
    ;;
*)
    echo "usage: engines.sh [build|env|path <name>]" >&2
    exit 2
    ;;
esac
