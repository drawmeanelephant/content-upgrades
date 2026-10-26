#!/bin/sh
# Regenerate the frozen artifacts in artifact/ from content/.
#
# usage: build.sh [--check]
#   --check  rebuild into a scratch dir and fail if it differs from the
#            committed artifact/ (the freeze is stale or the boris binary moved)
#
# The artifacts are byte-deterministic for a given boris binary and content.
set -eu

BORIS=${BORIS:-boris}
check=0
case ${1:-} in
  --check) check=1 ;;
  "") ;;
  *) echo "usage: build.sh [--check]" >&2; exit 2 ;;
esac

# boris refuses output paths outside the working directory (WorkspaceEscape),
# so scratch output lives inside the site.
cd -- "$(dirname -- "$0")"
tmp=.build-tmp
rm -rf "$tmp"
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT TERM

"$BORIS" --input content --html-dir "$tmp/dist" --theme themes/boris --quiet
"$BORIS" --input content --out "$tmp/ir" --quiet
"$BORIS" --input content --rag-dir "$tmp/rag" --quiet

mkdir -p "$tmp/artifact/rag"
cp "$tmp/dist/_boris/search/search-index.json" "$tmp/artifact/"
cp "$tmp/ir/graph.json" "$tmp/ir/completion.json" "$tmp/artifact/"
cp "$tmp"/rag/working-*.md "$tmp/rag/manifest.json" "$tmp/artifact/rag/"

if [ "$check" = 1 ]; then
  diff -r artifact "$tmp/artifact"
  echo "build.sh: artifact/ is current ($("$BORIS" --version))"
else
  rm -rf artifact
  mv "$tmp/artifact" artifact
  echo "build.sh: wrote artifact/ ($("$BORIS" --version))"
fi
