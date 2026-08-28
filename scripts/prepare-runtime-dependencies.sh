#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
WORK_ROOT="$REPO_ROOT/.build"
CONTAINER_ROOT="$WORK_ROOT/apple-container-compat"
PATCH_FILE="$REPO_ROOT/compat/apple-container-runtime-owned-resources.patch"
STATE_FILE="$CONTAINER_ROOT/.netbsd-vz-compat-revision"
CONTAINER_REVISION=d6de5694200468d99a61662bfb9bb3aba763e3e5

fail() { echo "error: $*" >&2; exit 1; }

[ -f "$PATCH_FILE" ] || fail "compatibility patch is missing: $PATCH_FILE"
PATCH_SHA512=$(/usr/bin/shasum -a 512 "$PATCH_FILE" | /usr/bin/awk '{print $1}')
EXPECTED_STATE="$CONTAINER_REVISION:$PATCH_SHA512"
if [ -f "$STATE_FILE" ] && [ "$(/bin/cat "$STATE_FILE")" = "$EXPECTED_STATE" ]; then
    exit 0
fi

case "$CONTAINER_ROOT" in
    "$WORK_ROOT"/*) /bin/rm -rf -- "$CONTAINER_ROOT" ;;
    *) fail "unsafe compatibility checkout path: $CONTAINER_ROOT" ;;
esac

/bin/mkdir -p "$WORK_ROOT"
/usr/bin/git clone --filter=blob:none --no-checkout https://github.com/apple/container.git "$CONTAINER_ROOT"
/usr/bin/git -C "$CONTAINER_ROOT" checkout --detach "$CONTAINER_REVISION"
/usr/bin/git -C "$CONTAINER_ROOT" apply --check "$PATCH_FILE"
/usr/bin/git -C "$CONTAINER_ROOT" apply "$PATCH_FILE"
printf '%s\n' "$EXPECTED_STATE" > "$STATE_FILE"
echo "Prepared Apple Container compatibility checkout at $CONTAINER_ROOT"
