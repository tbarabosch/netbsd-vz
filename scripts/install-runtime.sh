#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
INSTALL_ROOT=${CONTAINER_INSTALL_ROOT:-/usr/local}
PLUGIN_ROOT="$INSTALL_ROOT/libexec/container-plugins"
BUILD_ROOT="$REPO_ROOT/.build/runtime"

for plugin in container-runtime-netbsd netbsd; do
    [ -x "$BUILD_ROOT/$plugin" ] || { echo "error: run make runtime first" >&2; exit 1; }
    destination="$PLUGIN_ROOT/$plugin"
    /bin/mkdir -p "$destination/bin"
    /usr/bin/install -m 0555 "$BUILD_ROOT/$plugin" "$destination/bin/$plugin"
    /usr/bin/install -m 0444 "$REPO_ROOT/runtime/plugins/$plugin/config.toml" "$destination/config.toml"
done
RUNTIME_DESTINATION="$PLUGIN_ROOT/container-runtime-netbsd"
/usr/bin/install -m 0555 "$REPO_ROOT/.build/out/netbsd-vz-agent" \
    "$RUNTIME_DESTINATION/bin/netbsd-vz-agent"
/bin/rm -rf -- "$RUNTIME_DESTINATION/platform-kit.part"
/bin/cp -cR "$REPO_ROOT/.build/platform-kit/root" "$RUNTIME_DESTINATION/platform-kit.part"
/bin/rm -rf -- "$RUNTIME_DESTINATION/platform-kit"
/bin/mv "$RUNTIME_DESTINATION/platform-kit.part" "$RUNTIME_DESTINATION/platform-kit"
echo "Installed NetBSD plugins under $PLUGIN_ROOT"
