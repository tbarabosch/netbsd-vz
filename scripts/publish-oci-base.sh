#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
ARCHIVE="$REPO_ROOT/.build/out/netbsd-oci-netbsd-11.0.tar"
LAYOUT="$REPO_ROOT/.build/out/netbsd-oci-layout"
PUSH=0

case "${1:-}" in
    "") ;;
    --push) PUSH=1 ;;
    *) echo "usage: $0 [--push]" >&2; exit 64 ;;
esac

[ -f "$ARCHIVE" ] || { echo "error: run make oci-base first" >&2; exit 1; }
command -v container >/dev/null 2>&1 || { echo "error: Apple container CLI is required" >&2; exit 1; }

EXPECTED_MANIFEST=$(/usr/bin/jq -r '.manifests[0].digest' "$LAYOUT/index.json")
if ! container image inspect 11.0 2>/dev/null |
    /usr/bin/jq -e --arg digest "$EXPECTED_MANIFEST" \
        '.[0].variants | any(.digest == $digest)' >/dev/null; then
    container image load --input "$ARCHIVE"
fi
container image tag 11.0 ghcr.io/tbarabosch/netbsd:11.0
container image tag 11 ghcr.io/tbarabosch/netbsd:11

if [ "$PUSH" -eq 1 ]; then
    container image push --platform netbsd/arm64 ghcr.io/tbarabosch/netbsd:11.0
    container image push --platform netbsd/arm64 ghcr.io/tbarabosch/netbsd:11
fi

if [ "$PUSH" -eq 1 ]; then
    echo "Published ghcr.io/tbarabosch/netbsd:11.0 and :11"
else
    echo "Prepared ghcr.io/tbarabosch/netbsd:11.0 and :11 locally"
fi
