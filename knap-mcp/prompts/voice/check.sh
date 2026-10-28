#!/bin/sh
# Checks every few-shot example and mock reply against the voice contract:
# facts, names, numbers, urls, quotes and footnote refs kept verbatim, no
# markup dropped (markup chars and non-ASCII code points alike) and only
# balanced inline formatting (`**`, `*`, `~~` only over words the reply
# added, code spans quoting the input, allowlisted emoji) added, plain
# slots kept plain, text length bounds, tone budgets, and the same inputs
# across all three tones. testdata/bad.jsonl proves the guard bites.
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

# src/voice.zig's tests compare its assembly with these goldens.
for t in mild spicy feral; do
	if ! sh "$here/assemble.sh" system "$t" | cmp -s - "$here/testdata/system.$t.txt"; then
		echo "FAIL testdata/system.$t.txt: stale; regenerate: sh assemble.sh system $t > testdata/system.$t.txt"
		exit 1
	fi
done

exec awk -v mode=check -f "$here/voice.awk" \
	"$data"/*.sample.json \
	"$here/examples/mild.jsonl" "$here/examples/spicy.jsonl" "$here/examples/feral.jsonl" \
	"$here/mock/mild.jsonl" "$here/mock/spicy.jsonl" "$here/mock/feral.jsonl" \
	"$here/testdata/bad.jsonl"
