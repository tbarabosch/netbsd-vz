#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
WORK_ROOT="$REPO_ROOT/.build"

case "$WORK_ROOT" in
    "$REPO_ROOT/.build") ;;
    *) echo "error: unexpected build workspace: $WORK_ROOT" >&2; exit 1 ;;
esac

if [ -d "$WORK_ROOT/disk/root/var/spool/ftp/hidden" ]; then
    /bin/chmod u+rwx "$WORK_ROOT/disk/root/var/spool/ftp/hidden"
fi

for target in \
    "$WORK_ROOT/obj" "$WORK_ROOT/out" "$WORK_ROOT/bin" \
    "$WORK_ROOT/disk" "$WORK_ROOT/run"; do
    case "$target" in
        "$WORK_ROOT"/*) /bin/rm -rf -- "$target" ;;
        *) echo "error: refusing to remove $target" >&2; exit 1 ;;
    esac
done

echo "Cleaned generated files; preserved downloads, source, and cross tools."
