#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
WORK_ROOT="$REPO_ROOT/.build"
DOWNLOAD_ROOT="$WORK_ROOT/downloads"
AGENT_ROOT="$WORK_ROOT/agent"
SYSROOT="$AGENT_ROOT/sysroot"
TOOLS_ROOT="$WORK_ROOT/tools/bin"
OUTPUT_ROOT="$WORK_ROOT/out"
OUTPUT_AGENT="$OUTPUT_ROOT/netbsd-vz-agent"
STATE_FILE="$AGENT_ROOT/.sysroot-fingerprint"

NETBSD_VERSION=11.0
SETS_URL="https://cdn.netbsd.org/pub/NetBSD/NetBSD-$NETBSD_VERSION/evbarm-aarch64/binary/sets"
COMP_SHA512=0719f3d94fd5cdedf83ad7418f1e254c898b388c320f28d3d39b8abf96fe6ea58b605be8dc9e02d4d76021f87e3f0cd2bc327560e887abc572fbae04742305fd
COMP_ARCHIVE="$DOWNLOAD_ROOT/NetBSD-$NETBSD_VERSION-evbarm-aarch64-comp.tar.xz"

fail() { echo "error: $*" >&2; exit 1; }
sha512() { /usr/bin/shasum -a 512 "$1" | /usr/bin/awk '{print $1}'; }
verify() { [ "$(sha512 "$1")" = "$2" ] || fail "$3 failed SHA-512 verification: $1"; }

[ "$(/usr/bin/uname -s)" = Darwin ] || fail "the agent cross-builder requires macOS"
[ -x "$TOOLS_ROOT/aarch64--netbsd-gcc" ] || fail "NetBSD cross compiler is missing; run make build first"
/bin/mkdir -p "$DOWNLOAD_ROOT" "$OUTPUT_ROOT" "$AGENT_ROOT"
if [ ! -f "$COMP_ARCHIVE" ]; then
	part="$COMP_ARCHIVE.part"
	/bin/rm -f -- "$part"
	/usr/bin/curl --fail --location --retry 3 --output "$part" "$SETS_URL/comp.tar.xz"
	verify "$part" "$COMP_SHA512" "NetBSD comp set"
	/bin/mv -- "$part" "$COMP_ARCHIVE"
fi
verify "$COMP_ARCHIVE" "$COMP_SHA512" "NetBSD comp set"

fingerprint=$(printf '%s\n' "sysroot-v2" "$NETBSD_VERSION" "$COMP_SHA512" | /usr/bin/shasum -a 512 | /usr/bin/awk '{print $1}')
cached=
[ ! -f "$STATE_FILE" ] || cached=$(/bin/cat "$STATE_FILE")
if [ "$cached" != "$fingerprint" ] || [ ! -f "$SYSROOT/usr/include/sys/types.h" ]; then
	case "$SYSROOT" in "$WORK_ROOT"/*) /bin/rm -rf -- "$SYSROOT" ;; *) fail "unsafe sysroot path" ;; esac
	/bin/mkdir -p "$SYSROOT"
	/usr/bin/tar -xJf "$COMP_ARCHIVE" -C "$SYSROOT" './usr/include/*' './usr/lib/*'
	/usr/bin/tar -xJf "$WORK_ROOT/downloads/NetBSD-$NETBSD_VERSION-evbarm-aarch64-base.tar.xz" \
		-C "$SYSROOT" ./usr/include/machine
	printf '%s\n' "$fingerprint" > "$STATE_FILE"
fi

output_part="$OUTPUT_AGENT.part"
/bin/rm -f -- "$output_part"
"$TOOLS_ROOT/aarch64--netbsd-gcc" --sysroot="$SYSROOT" \
	-std=c11 -O2 -pipe -Wall -Wextra -Werror -Wformat=2 -fstack-protector-strong \
	-I"$REPO_ROOT/agent/src" -I"$REPO_ROOT/protocol/c" \
	"$REPO_ROOT/agent/src/netbsd_vz_agent.c" \
	"$REPO_ROOT/agent/src/json.c" \
	"$REPO_ROOT/protocol/c/nvza_protocol.c" \
	-static -lutil -o "$output_part"
/usr/bin/file "$output_part" | /usr/bin/grep -q 'ELF 64-bit.*ARM aarch64' || fail "agent is not an AArch64 ELF executable"
/bin/chmod 0555 "$output_part"
/bin/mv -f -- "$output_part" "$OUTPUT_AGENT"
echo "Built $OUTPUT_AGENT"
