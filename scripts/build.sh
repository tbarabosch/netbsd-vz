#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
WORK_ROOT="$REPO_ROOT/.build"
DOWNLOAD_ROOT="$WORK_ROOT/downloads"
SOURCE_ROOT="$WORK_ROOT/source"
NETBSD_SRC="$SOURCE_ROOT/usr/src"
OBJECT_ROOT="$WORK_ROOT/obj"
TOOLS_ROOT="$WORK_ROOT/tools"
OUTPUT_ROOT="$WORK_ROOT/out"

NETBSD_VERSION=11.0
SOURCE_BASE_URL="https://cdn.netbsd.org/pub/NetBSD/NetBSD-$NETBSD_VERSION/source/sets"
SOURCE_SHA512=99a8f96202290ce203d98396305f3ae1e38b49663b1210447cb82d05ee1717969adb6101dab5f06050e9ef981bd6efb798ae1b2e8e7f0079ba5486da4ca82fcc
GNUSRC_SHA512=9dcbba3d56eadd012b9999fe3baa186c156a187793105675545fbebe1b536dd21b3042b678c981a664c0d68e7ef053d5f6c9a40fad780aecf93db43524d4496a
SHARESRC_SHA512=5e67c84962e8065f0b888bb3d8f5d6c140a00871a1f97c57ac2433e272b0c9abb1c148b5515995c974390f7b75d92e6347412f470de23a8857f32a62bb4f00cf
SYSSRC_SHA512=318d451ecc83749607d5448198c02663ea5f0b7f4cc74fb565747f86eead7b66b5809a37deee219dc6ddb2e5ee332d1cbb94c1a4e9db63620c3abd7586fb3057

SOURCE_ARCHIVE="$DOWNLOAD_ROOT/NetBSD-$NETBSD_VERSION-src.tgz"
GNUSRC_ARCHIVE="$DOWNLOAD_ROOT/NetBSD-$NETBSD_VERSION-gnusrc.tgz"
SHARESRC_ARCHIVE="$DOWNLOAD_ROOT/NetBSD-$NETBSD_VERSION-sharesrc.tgz"
SYSSRC_ARCHIVE="$DOWNLOAD_ROOT/NetBSD-$NETBSD_VERSION-syssrc.tgz"
PCI_MEMORY_PATCH="$REPO_ROOT/patches/virtio-pci-memory.patch"
VIRTIO_RESET_PATCH="$REPO_ROOT/patches/virtio-reset.patch"
VIOIF_MTU_PATCH="$REPO_ROOT/patches/vioif-mtu.patch"
SOURCE_STATE="$SOURCE_ROOT/.netbsd-vz-source-fingerprint"
TOOLS_STATE="$TOOLS_ROOT/.netbsd-vz-tools-fingerprint"
OUTPUT_KERNEL="$OUTPUT_ROOT/netbsd-GENERIC64"

fail()
{
    echo "error: $*" >&2
    exit 1
}

safe_remove()
{
    target=$1
    case "$target" in
        "$WORK_ROOT"/*) /bin/rm -rf -- "$target" ;;
        *) fail "refusing to remove path outside $WORK_ROOT: $target" ;;
    esac
}

require_executable()
{
    [ -x "$1" ] || fail "required executable not found: $1"
}

fail_with_log()
{
    message=$1
    log=$2
    echo "error: $message" >&2
    /usr/bin/tail -n 80 "$log" >&2
    exit 1
}

sha512()
{
    /usr/bin/shasum -a 512 "$1" | /usr/bin/awk '{print $1}'
}

verify_archive()
{
    archive=$1
    expected=$2
    label=$3
    actual=$(sha512 "$archive")
    [ "$actual" = "$expected" ] ||
        fail "$label failed SHA-512 verification: $archive"
}

fetch_archive()
{
    name=$1
    expected=$2
    destination=$3
    label=$4
    url="$SOURCE_BASE_URL/$name"

    if [ ! -f "$destination" ]; then
        echo "Downloading $label..."
        part="$destination.part"
        /bin/rm -f -- "$part"
        /usr/bin/curl --fail --location --retry 3 --output "$part" "$url"
        verify_archive "$part" "$expected" "$label"
        /bin/mv -- "$part" "$destination"
    fi
    verify_archive "$destination" "$expected" "$label"
}

patch_is_applied()
{
    /usr/bin/patch -C -R -f -s -d "$NETBSD_SRC" -p1 -i "$1" >/dev/null 2>&1
}

patch_is_applicable()
{
    /usr/bin/patch -C -f -s -d "$NETBSD_SRC" -p1 -i "$1" >/dev/null 2>&1
}

apply_patch_file()
{
    patch_file=$1
    label=$2
    if patch_is_applied "$patch_file"; then
        echo "Reusing applied $label"
    elif patch_is_applicable "$patch_file"; then
        echo "Applying $label..."
        /usr/bin/patch -f -s -d "$NETBSD_SRC" -p1 -i "$patch_file"
    else
        fail "$label is neither applicable nor already applied"
    fi
}

source_tree_complete()
{
    [ -x "$NETBSD_SRC/build.sh" ] &&
        [ -d "$NETBSD_SRC/external/gpl3/gcc" ] &&
        [ -d "$NETBSD_SRC/share/mk" ] &&
        [ -f "$NETBSD_SRC/sys/dev/pci/virtio_pci.c" ] &&
        [ -f "$NETBSD_SRC/sys/dev/pci/if_vioif.c" ] &&
        [ -f "$NETBSD_SRC/sys/arch/evbarm/conf/GENERIC64" ]
}

case "$WORK_ROOT" in
    "$REPO_ROOT/.build") ;;
    *) fail "unexpected build workspace: $WORK_ROOT" ;;
esac

[ "$(/usr/bin/uname -s)" = Darwin ] || fail "the native builder requires macOS"
[ "$(/usr/bin/uname -m)" = arm64 ] || fail "the native builder requires Apple Silicon"
require_executable /bin/sh
require_executable /usr/bin/awk
require_executable /usr/bin/curl
require_executable /usr/bin/patch
require_executable /usr/bin/shasum
require_executable /usr/bin/tar
require_executable /usr/bin/xcode-select
require_executable /usr/bin/xcrun
/usr/bin/xcode-select -p >/dev/null 2>&1 || fail "select Xcode or Command Line Tools first"
/usr/bin/xcrun --find clang >/dev/null 2>&1 || fail "Xcode clang is unavailable"

if [ -n "${NETBSD_VZ_JOBS+x}" ]; then
    JOBS=$NETBSD_VZ_JOBS
else
    JOBS=$(/usr/sbin/sysctl -n hw.logicalcpu)
fi
case "$JOBS" in
    ''|*[!0-9]*|0) fail "NETBSD_VZ_JOBS must be a positive integer" ;;
esac

for patch_file in "$PCI_MEMORY_PATCH" "$VIRTIO_RESET_PATCH" "$VIOIF_MTU_PATCH"; do
    [ -f "$patch_file" ] || fail "patch input is missing: $patch_file"
done

/bin/mkdir -p "$DOWNLOAD_ROOT" "$OUTPUT_ROOT"
fetch_archive src.tgz "$SOURCE_SHA512" "$SOURCE_ARCHIVE" "NetBSD base source"
fetch_archive gnusrc.tgz "$GNUSRC_SHA512" "$GNUSRC_ARCHIVE" "NetBSD GNU source"
fetch_archive sharesrc.tgz "$SHARESRC_SHA512" "$SHARESRC_ARCHIVE" "NetBSD shared source"
fetch_archive syssrc.tgz "$SYSSRC_SHA512" "$SYSSRC_ARCHIVE" "NetBSD kernel source"

SOURCE_FINGERPRINT=$(
    {
        printf '%s\n' "$NETBSD_VERSION" "$SOURCE_SHA512" "$GNUSRC_SHA512" "$SHARESRC_SHA512" "$SYSSRC_SHA512"
        for patch_file in "$PCI_MEMORY_PATCH" "$VIRTIO_RESET_PATCH" "$VIOIF_MTU_PATCH"; do
            sha512 "$patch_file"
        done
    } | /usr/bin/shasum -a 512 | /usr/bin/awk '{print $1}'
)

CACHED_SOURCE_FINGERPRINT=
if [ -f "$SOURCE_STATE" ]; then
    CACHED_SOURCE_FINGERPRINT=$(/bin/cat "$SOURCE_STATE")
fi
if [ "$CACHED_SOURCE_FINGERPRINT" != "$SOURCE_FINGERPRINT" ] ||
   ! source_tree_complete; then
    echo "Extracting pristine verified NetBSD 11.0 source sets..."
    safe_remove "$SOURCE_ROOT"
    safe_remove "$OBJECT_ROOT"
    safe_remove "$OUTPUT_ROOT"
    /bin/mkdir -p "$SOURCE_ROOT" "$OUTPUT_ROOT"
    /usr/bin/tar -xzf "$SOURCE_ARCHIVE" -C "$SOURCE_ROOT"
    /usr/bin/tar -xzf "$GNUSRC_ARCHIVE" -C "$SOURCE_ROOT"
    /usr/bin/tar -xzf "$SHARESRC_ARCHIVE" -C "$SOURCE_ROOT"
    /usr/bin/tar -xzf "$SYSSRC_ARCHIVE" -C "$SOURCE_ROOT"
fi
source_tree_complete || fail "the verified NetBSD source sets extracted incompletely"

apply_patch_file "$PCI_MEMORY_PATCH" "generic Virtio PCI memory-decoding fix"
apply_patch_file "$VIRTIO_RESET_PATCH" "generic Virtio reset-completion fix"
apply_patch_file "$VIOIF_MTU_PATCH" "generic Virtio network MTU fix"
[ ! -e "$NETBSD_SRC/sys/arch/evbarm/conf/VZ64" ] ||
    fail "pristine EFI source unexpectedly contains a VZ64 configuration"
/usr/bin/grep -q '^acpifdt\*.*at fdt' "$NETBSD_SRC/sys/arch/evbarm/conf/GENERIC64" ||
    fail "GENERIC64 no longer contains the ACPI/FDT bridge"
/usr/bin/grep -q '^acpipchb\*.*at acpi' "$NETBSD_SRC/sys/arch/evbarm/conf/GENERIC64" ||
    fail "GENERIC64 no longer contains the ACPI PCI host bridge"
printf '%s\n' "$SOURCE_FINGERPRINT" > "$SOURCE_STATE"

MACOS_VERSION=$(/usr/bin/sw_vers -productVersion)
XCODE_VERSION=$(/usr/bin/xcodebuild -version 2>/dev/null | /usr/bin/tr '\n' ' ')
CLANG_VERSION=$(/usr/bin/xcrun clang --version | /usr/bin/sed -n '1p')
TOOLS_FINGERPRINT=$(printf '%s\n' "$REPO_ROOT" "$NETBSD_VERSION" "$SOURCE_SHA512" "$GNUSRC_SHA512" "$SHARESRC_SHA512" "$SYSSRC_SHA512" "$MACOS_VERSION" "$XCODE_VERSION" "$CLANG_VERSION" |
    /usr/bin/shasum -a 512 | /usr/bin/awk '{print $1}')

if [ -f "$TOOLS_STATE" ]; then
    CACHED_TOOLS_FINGERPRINT=$(/bin/cat "$TOOLS_STATE")
    if [ "$CACHED_TOOLS_FINGERPRINT" != "$TOOLS_FINGERPRINT" ]; then
        echo "Host, Xcode, source, or repository path changed; rebuilding cross tools..."
        safe_remove "$TOOLS_ROOT"
        safe_remove "$OBJECT_ROOT"
        safe_remove "$OUTPUT_ROOT"
    fi
elif [ -e "$TOOLS_ROOT" ]; then
    echo "Unidentified or relocated tool cache cannot be reused; rebuilding it..."
    safe_remove "$TOOLS_ROOT"
    safe_remove "$OBJECT_ROOT"
    safe_remove "$OUTPUT_ROOT"
fi

/bin/mkdir -p "$OBJECT_ROOT" "$OUTPUT_ROOT"
cd "$NETBSD_SRC"
if [ ! -x "$TOOLS_ROOT/bin/nbmake-evbarm" ] ||
   [ ! -x "$TOOLS_ROOT/bin/aarch64--netbsd-gcc" ]; then
    echo "Building host-native NetBSD cross tools with $JOBS jobs..."
    TOOLS_LOG="$OBJECT_ROOT/tools-build.log"
    if ! HOST_SH=/bin/sh ./build.sh -U -j "$JOBS" -O "$OBJECT_ROOT" -T "$TOOLS_ROOT" -m evbarm -a aarch64 tools >"$TOOLS_LOG" 2>&1; then
        fail_with_log "cross-tool build failed; log: $TOOLS_LOG" "$TOOLS_LOG"
    fi
    /bin/mkdir -p "$TOOLS_ROOT"
    printf '%s\n' "$TOOLS_FINGERPRINT" > "$TOOLS_STATE"
else
    echo "Reusing host-native cross tools from $TOOLS_ROOT"
fi

echo "Building stock NetBSD GENERIC64..."
KERNEL_LOG="$OBJECT_ROOT/generic64-build.log"
if ! HOST_SH=/bin/sh ./build.sh -U -u -j "$JOBS" -O "$OBJECT_ROOT" -T "$TOOLS_ROOT" -m evbarm -a aarch64 kernel=GENERIC64 >"$KERNEL_LOG" 2>&1; then
    fail_with_log "GENERIC64 build failed; log: $KERNEL_LOG" "$KERNEL_LOG"
fi

BUILT_KERNEL="$OBJECT_ROOT/sys/arch/evbarm/compile/GENERIC64/netbsd"
[ -f "$BUILT_KERNEL" ] || fail "kernel build did not produce $BUILT_KERNEL"
OUTPUT_PART="$OUTPUT_KERNEL.part"
/bin/rm -f -- "$OUTPUT_PART"
/bin/cp "$BUILT_KERNEL" "$OUTPUT_PART"
/usr/bin/file "$OUTPUT_PART" | /usr/bin/grep -q 'ELF 64-bit.*ARM aarch64' ||
    fail "GENERIC64 output is not an AArch64 ELF kernel"
/bin/mv -- "$OUTPUT_PART" "$OUTPUT_KERNEL"

KERNEL_BYTES=$(/usr/bin/stat -f '%z' "$OUTPUT_KERNEL")
echo "Built $OUTPUT_KERNEL ($KERNEL_BYTES bytes)"
