#!/bin/sh
# Checks every few-shot example and mock reply against the voice contract:
# facts, names, numbers, urls, quotes and footnote refs kept verbatim, no
# markup or line breaks added, length bounds, tone budgets, and the same
# inputs across all three tones. testdata/bad.jsonl proves the guard bites.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
data=$here/../../data
LC_ALL=C
export LC_ALL

for f in system.md mild.md spicy.md feral.md; do
	if [ ! -s "$here/$f" ]; then
		echo "FAIL $f: missing or empty"
		exit 1
	fi
done

exec awk -v mode=check -f "$here/voice.awk" \
	"$data"/*.sample.json \
	"$here/examples/mild.jsonl" "$here/examples/spicy.jsonl" "$here/examples/feral.jsonl" \
	"$here/mock/mild.jsonl" "$here/mock/spicy.jsonl" "$here/mock/feral.jsonl" \
	"$here/testdata/bad.jsonl"
