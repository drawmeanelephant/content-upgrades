#!/bin/sh
# Prints the exact messages of one knap_voice call, with no trailing newline.
#   assemble.sh system <tone>                 system message (mild|spicy|feral)
#   assemble.sh user <field> <role> <value>   user message
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LC_ALL=C
export LC_ALL

usage() {
	echo "usage: assemble.sh system <mild|spicy|feral>" >&2
	echo "       assemble.sh user <field> <role> <value>" >&2
	exit 2
}

case ${1-} in
system)
	[ $# -eq 2 ] || usage
	case $2 in mild | spicy | feral) ;; *) usage ;; esac
	exec awk -v mode=system -f "$here/voice.awk" \
		"$here/system.md" "$here/$2.md" "$here/examples/$2.jsonl"
	;;
user)
	[ $# -eq 4 ] || usage
	printf 'Field: %s\nRole: %s\nInput: %s' "$2" "$3" "$4"
	;;
*)
	usage
	;;
esac
