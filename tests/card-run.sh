#!/bin/sh
# card-run.sh FILE -- run one makefile of docs/card.md, as the card check
# asks.  It is the Makefile of a scratch directory, so a recipe that writes
# a file writes it there.
dir=$(mktemp -d) || exit 1
trap 'rm -rf "$dir"' EXIT
cp "$1" "$dir/Makefile"
"${X:-x}" -l make -- -C "$dir"
