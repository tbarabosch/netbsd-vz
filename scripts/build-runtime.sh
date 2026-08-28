#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
RUNTIME_ROOT="$REPO_ROOT/runtime"
OUTPUT_ROOT="$REPO_ROOT/.build/runtime"
ENTITLEMENTS="$RUNTIME_ROOT/container-runtime-netbsd.entitlements"

[ "$(/usr/bin/uname -s)" = Darwin ] || { echo "error: runtime requires macOS" >&2; exit 1; }
"$SCRIPT_DIR/prepare-runtime-dependencies.sh"
cd "$RUNTIME_ROOT"
/usr/bin/xcrun swift build -c release
/bin/mkdir -p "$OUTPUT_ROOT"
for binary in container-runtime-netbsd netbsd netbsd-oci-base; do
    source_path="$RUNTIME_ROOT/.build/release/$binary"
    output_path="$OUTPUT_ROOT/$binary"
    /bin/cp "$source_path" "$output_path.part"
    if [ "$binary" = container-runtime-netbsd ]; then
        /usr/bin/codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$output_path.part"
    else
        /usr/bin/codesign --force --sign - --timestamp=none "$output_path.part"
    fi
    /bin/mv -f "$output_path.part" "$output_path"
done
echo "Built runtime plugins in $OUTPUT_ROOT"
