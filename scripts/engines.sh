#!/bin/sh
# Pinned engine binaries for knap-mcp. A pin bump is a one-line change to
# the SHAs below, in its own PR.
#
#   scripts/engines.sh             build any missing pin
#   scripts/engines.sh env         print export lines for the pinned binaries
#   scripts/engines.sh path <name> print one pinned binary path (k4o|dogbed)
#
# Each pin lives in $KNAP_ENGINES_DIR/<name>-<sha7>/<name>. Builds run on a
# `git archive` export in a temp dir and are moved into place when done, so
# the source working trees are never touched and an existing pin dir is
# never rebuilt or overwritten.
#
# The archive comes from $KNAP_ENGINES_SRC/<name> (default ~/dev) when that
# checkout already has the pinned commit. Otherwise the commit is shallow-
# fetched from https://github.com/drawmeanelephant/<name> into a scratch
# repo that is deleted on exit; $KNAP_ENGINES_SRC is never written to.
# KNAP_ENGINES_OFFLINE=1 disables the fetch and fails with the old
# "fetch it there first" error instead.
#
# -Dcpu=baseline: the cache dir is shared across machines (and copied
# between CI runners), so a native-CPU build restored onto older hardware
# SIGILLs on exec. Baseline keeps pins portable.
set -eu

K4O_SHA=aeba16352a7b6c7fd8d54db53cb506bdf5ead994
DOGBED_SHA=d96b125ab0d846d29a13f65e44e62799c7e9f3d8

ENGINES_DIR=${KNAP_ENGINES_DIR:-$HOME/.cache/knap-engines}
SRC_DIR=${KNAP_ENGINES_SRC:-$HOME/dev}

# Scratch repos shallow-fetched by fetch_repo; removed on exit.
FETCH_REPOS=
trap 'for d in $FETCH_REPOS; do rm -rf "$d"; done' EXIT

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

# fetch_repo <name>: shallow-fetch the pinned commit into a scratch repo —
# the recipe CI used — and set FETCHED to its path. $SRC_DIR is read-only;
# the scratch repo is removed by the EXIT trap.
fetch_repo() {
    f_sha=$(pin_sha "$1")
    f_url=https://github.com/drawmeanelephant/$1
    echo "engines: $1@$f_sha not in $SRC_DIR/$1; fetching $f_url"
    FETCHED=$(mktemp -d "${TMPDIR:-/tmp}/knap-engine-src.XXXXXX")
    FETCH_REPOS="$FETCH_REPOS $FETCHED"
    git -C "$FETCHED" init -q
    git -C "$FETCHED" remote add origin "$f_url"
    if ! git -C "$FETCHED" fetch -q --depth 1 origin "$f_sha"; then
        echo "engines: fetch of $f_sha from $f_url failed" >&2
        exit 1
    fi
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
        if [ "${KNAP_ENGINES_OFFLINE:-0}" = "1" ]; then
            echo "engines: commit $sha not found in $repo; fetch it there first" >&2
            return 1
        fi
        fetch_repo "$name"
        repo=$FETCHED
    fi

    echo "engines: building $name at $sha from $repo"
    mkdir -p "$ENGINES_DIR"
    tmp=$(mktemp -d "$ENGINES_DIR/.build-$name.XXXXXX")
    mkdir "$tmp/src" "$tmp/out"
    if ! {
        git -C "$repo" archive --format=tar "$sha" | tar -x -C "$tmp/src" &&
            (cd "$tmp/src" && zig build -Doptimize=ReleaseSafe -Dcpu=baseline) &&
            cp "$tmp/src/zig-out/bin/$name" "$tmp/out/$name"
    }; then
        rm -rf "$tmp"
        echo "engines: $name build failed" >&2
        return 1
    fi
    echo "$name built from git archive $sha -Doptimize=ReleaseSafe -Dcpu=baseline" >"$tmp/out/PROVENANCE"
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
