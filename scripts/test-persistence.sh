#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
WORK_ROOT="$REPO_ROOT/.build"
SOURCE_DISK="$WORK_ROOT/out/netbsd-vz.raw"
RUN_ROOT="$WORK_ROOT/run"
TEST_ROOT="$RUN_ROOT/efi-persistence.$$"
TEST_DISK="$TEST_ROOT/netbsd-vz.raw"
EFI_STATE="$TEST_ROOT/state"

case "$TEST_ROOT" in
    "$WORK_ROOT/run"/*) ;;
    *) echo "error: unsafe persistence test path: $TEST_ROOT" >&2; exit 1 ;;
esac
[ -f "$SOURCE_DISK" ] || {
    echo "error: EFI disk image is missing: $SOURCE_DISK" >&2
    exit 1
}

cleanup()
{
    /bin/rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT HUP INT TERM
/bin/mkdir -p "$EFI_STATE"
/bin/cp -c "$SOURCE_DISK" "$TEST_DISK"

echo "Persistence boot 1/2: writing marker with fresh EFI state..."
"$SCRIPT_DIR/run.sh" --disk "$TEST_DISK" --efi-state "$EFI_STATE" \
    --smoke --persistence-write
echo "Persistence boot 2/2: reading marker with reused EFI state..."
"$SCRIPT_DIR/run.sh" --disk "$TEST_DISK" --efi-state "$EFI_STATE" \
    --smoke --persistence-read
echo "EFI disk and variable-state persistence passed."
