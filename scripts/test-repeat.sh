#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

run=1
while [ "$run" -le 5 ]; do
    echo "EFI cold boot $run/5..."
    "$SCRIPT_DIR/run.sh" --smoke
    run=$((run + 1))
done
echo "Five consecutive EFI cold boots passed."
