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
SOURCE_BASE_URL="https://cdn.netbsd.org/pub/NetBSD/NetBSD-${NETBSD_VERSION}/source/sets"
SOURCE_SHA512=99a8f96202290ce203d98396305f3ae1e38b49663b1210447cb82d05ee1717969adb6101dab5f06050e9ef981bd6efb798ae1b2e8e7f0079ba5486da4ca82fcc
GNUSRC_SHA512=9dcbba3d56eadd012b9999fe3baa186c156a187793105675545fbebe1b536dd21b3042b678c981a664c0d68e7ef053d5f6c9a40fad780aecf93db43524d4496a
SHARESRC_SHA512=5e67c84962e8065f0b888bb3d8f5d6c140a00871a1f97c57ac2433e272b0c9abb1c148b5515995c974390f7b75d92e6347412f470de23a8857f32a62bb4f00cf
SYSSRC_SHA512=318d451ecc83749607d5448198c02663ea5f0b7f4cc74fb565747f86eead7b66b5809a37deee219dc6ddb2e5ee332d1cbb94c1a4e9db63620c3abd7586fb3057

SOURCE_ARCHIVE="$DOWNLOAD_ROOT/NetBSD-${NETBSD_VERSION}-src.tgz"
GNUSRC_ARCHIVE="$DOWNLOAD_ROOT/NetBSD-${NETBSD_VERSION}-gnusrc.tgz"
SHARESRC_ARCHIVE="$DOWNLOAD_ROOT/NetBSD-${NETBSD_VERSION}-sharesrc.tgz"
SYSSRC_ARCHIVE="$DOWNLOAD_ROOT/NetBSD-${NETBSD_VERSION}-syssrc.tgz"
VIOCON_PATCH="$REPO_ROOT/patches/viocon-console.patch"
PLATFORM_PATCH="$REPO_ROOT/patches/vz-platform.patch"
VIOIF_MTU_PATCH="$REPO_ROOT/patches/vioif-mtu.patch"
VZ64_PATCH="$REPO_ROOT/patches/vz64-config.patch"
VZ64_CONFIG="$NETBSD_SRC/sys/arch/evbarm/conf/VZ64"
SOURCE_STATE="$SOURCE_ROOT/.netbsd-vz-source-fingerprint"
TOOLS_STATE="$TOOLS_ROOT/.netbsd-vz-tools-fingerprint"
OUTPUT_IMAGE="$OUTPUT_ROOT/netbsd-VZ64-vz.img"
VZ_IMAGE_BYTES=8388608

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
    /usr/bin/patch -C -R -f -s -d "$NETBSD_SRC" -p1 -i "$1" \
        >/dev/null 2>&1
}

patch_is_applicable()
{
    /usr/bin/patch -C -f -s -d "$NETBSD_SRC" -p1 -i "$1" \
        >/dev/null 2>&1
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
        [ -f "$NETBSD_SRC/sys/dev/virtio/viocon.c" ]
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

JOBS=${NETBSD_VZ_JOBS:-$(/usr/sbin/sysctl -n hw.logicalcpu)}
case "$JOBS" in
    ''|*[!0-9]*|0) fail "NETBSD_VZ_JOBS must be a positive integer" ;;
esac

/bin/mkdir -p "$DOWNLOAD_ROOT" "$OUTPUT_ROOT"
fetch_archive src.tgz "$SOURCE_SHA512" "$SOURCE_ARCHIVE" "NetBSD base source"
fetch_archive gnusrc.tgz "$GNUSRC_SHA512" "$GNUSRC_ARCHIVE" "NetBSD GNU source"
fetch_archive sharesrc.tgz "$SHARESRC_SHA512" "$SHARESRC_ARCHIVE" "NetBSD shared source"
fetch_archive syssrc.tgz "$SYSSRC_SHA512" "$SYSSRC_ARCHIVE" "NetBSD kernel source"

VIOCON_PATCH_SHA512=$(sha512 "$VIOCON_PATCH")
PLATFORM_PATCH_SHA512=$(sha512 "$PLATFORM_PATCH")
VIOIF_MTU_PATCH_SHA512=$(sha512 "$VIOIF_MTU_PATCH")
VZ64_PATCH_SHA512=$(sha512 "$VZ64_PATCH")
SOURCE_FINGERPRINT=$(printf '%s\n' \
    "$NETBSD_VERSION" "$SOURCE_SHA512" "$GNUSRC_SHA512" \
    "$SHARESRC_SHA512" "$SYSSRC_SHA512" \
    "$VIOCON_PATCH_SHA512" "$PLATFORM_PATCH_SHA512" \
    "$VIOIF_MTU_PATCH_SHA512" "$VZ64_PATCH_SHA512" |
    /usr/bin/shasum -a 512 | /usr/bin/awk '{print $1}')

if [ -f "$SOURCE_STATE" ]; then
    CACHED_SOURCE_FINGERPRINT=$(/bin/cat "$SOURCE_STATE")
    if [ "$CACHED_SOURCE_FINGERPRINT" != "$SOURCE_FINGERPRINT" ]; then
        echo "NetBSD source or patch inputs changed; refreshing patched source and objects..."
        safe_remove "$SOURCE_ROOT"
        safe_remove "$OBJECT_ROOT"
        safe_remove "$OUTPUT_ROOT"
    fi
elif source_tree_complete; then
    if patch_is_applied "$VIOCON_PATCH" &&
       patch_is_applied "$PLATFORM_PATCH" &&
       patch_is_applied "$VIOIF_MTU_PATCH" &&
       patch_is_applied "$VZ64_PATCH"; then
        echo "Adopting the verified portable patched source cache..."
        printf '%s\n' "$SOURCE_FINGERPRINT" > "$SOURCE_STATE"
    else
        echo "Existing source cache has unknown patch state; extracting it again..."
        safe_remove "$SOURCE_ROOT"
        safe_remove "$OBJECT_ROOT"
        safe_remove "$OUTPUT_ROOT"
    fi
fi

if ! source_tree_complete; then
    echo "Extracting verified NetBSD 11.0 source sets..."
    /bin/mkdir -p "$SOURCE_ROOT"
    /usr/bin/tar -xzf "$SOURCE_ARCHIVE" -C "$SOURCE_ROOT"
    /usr/bin/tar -xzf "$GNUSRC_ARCHIVE" -C "$SOURCE_ROOT"
    /usr/bin/tar -xzf "$SHARESRC_ARCHIVE" -C "$SOURCE_ROOT"
    /usr/bin/tar -xzf "$SYSSRC_ARCHIVE" -C "$SOURCE_ROOT"
fi
source_tree_complete || fail "the verified NetBSD source sets extracted incompletely"

apply_patch_file "$VIOCON_PATCH" "viocon kernel-console patch"
apply_patch_file "$PLATFORM_PATCH" "Apple VZ platform patch"
apply_patch_file "$VIOIF_MTU_PATCH" "Virtio network MTU patch"
apply_patch_file "$VZ64_PATCH" "VZ64 kernel-configuration patch"
for device in armfdt0 'psci[*]' 'gicvthree[*]' 'gtmr[*]' 'plrtc[*]' \
    'pcihost[*]' 'virtio[*]' 'viocon[*]' 'ld[*]' 'vioif[*]' 'viornd[*]'; do
    /usr/bin/grep -Eq "^[[:space:]]*$device[[:space:]]" "$VZ64_CONFIG" ||
        fail "VZ64 is missing required device configuration: $device"
done
printf '%s\n' "$SOURCE_FINGERPRINT" > "$SOURCE_STATE"

MACOS_VERSION=$(/usr/bin/sw_vers -productVersion)
XCODE_VERSION=$(/usr/bin/xcodebuild -version 2>/dev/null | /usr/bin/tr '\n' ' ')
CLANG_VERSION=$(/usr/bin/xcrun clang --version | /usr/bin/sed -n '1p')
TOOLS_FINGERPRINT=$(printf '%s\n' \
    "$REPO_ROOT" "$NETBSD_VERSION" "$SOURCE_SHA512" "$GNUSRC_SHA512" \
    "$SHARESRC_SHA512" "$SYSSRC_SHA512" "$MACOS_VERSION" \
    "$XCODE_VERSION" "$CLANG_VERSION" |
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
    if ! HOST_SH=/bin/sh ./build.sh \
        -U -j "$JOBS" \
        -O "$OBJECT_ROOT" \
        -T "$TOOLS_ROOT" \
        -m evbarm -a aarch64 \
        tools >"$TOOLS_LOG" 2>&1; then
        fail_with_log "cross-tool build failed; log: $TOOLS_LOG" "$TOOLS_LOG"
    fi
    /bin/mkdir -p "$TOOLS_ROOT"
    printf '%s\n' "$TOOLS_FINGERPRINT" > "$TOOLS_STATE"
else
    echo "Reusing host-native cross tools from $TOOLS_ROOT"
fi

echo "Building patched NetBSD VZ64 kernel..."
KERNEL_LOG="$OBJECT_ROOT/vz64-build.log"
if ! HOST_SH=/bin/sh ./build.sh \
    -U -u -j "$JOBS" \
    -O "$OBJECT_ROOT" \
    -T "$TOOLS_ROOT" \
    -m evbarm -a aarch64 \
    kernel=VZ64 >"$KERNEL_LOG" 2>&1; then
    fail_with_log "VZ64 build failed; log: $KERNEL_LOG" "$KERNEL_LOG"
fi

BUILT_KERNEL="$OBJECT_ROOT/sys/arch/evbarm/compile/VZ64/netbsd"
BUILT_IMAGE="$OBJECT_ROOT/sys/arch/evbarm/compile/VZ64/netbsd.img"
[ -f "$BUILT_KERNEL" ] || fail "kernel build did not produce $BUILT_KERNEL"
[ -f "$BUILT_IMAGE" ] || fail "kernel build did not produce $BUILT_IMAGE"
LINKED_IMAGE_BYTES=$(/usr/bin/stat -f '%z' "$BUILT_IMAGE")
[ "$LINKED_IMAGE_BYTES" -lt "$VZ_IMAGE_BYTES" ] ||
    fail "linked VZ64 image does not fit the $VZ_IMAGE_BYTES-byte VZ loader reservation"
PADDED_IMAGE="$OUTPUT_ROOT/.netbsd-VZ64-vz.payload"
OUTPUT_PART="$OUTPUT_IMAGE.part"
/bin/rm -f -- "$PADDED_IMAGE" "$OUTPUT_PART"
/bin/cp "$BUILT_IMAGE" "$PADDED_IMAGE"
/usr/bin/truncate -s "$VZ_IMAGE_BYTES" "$PADDED_IMAGE"
"$TOOLS_ROOT/bin/nbmkubootimage" -f arm64 -u -a 0x200000 \
    "$PADDED_IMAGE" "$OUTPUT_PART" >/dev/null
/bin/rm -f -- "$PADDED_IMAGE"

IMAGE_BYTES=$(/usr/bin/stat -f '%z' "$OUTPUT_PART")
[ "$IMAGE_BYTES" -eq "$VZ_IMAGE_BYTES" ] ||
    fail "VZ64 image is not exactly the $VZ_IMAGE_BYTES-byte VZ loader reservation"
MAGIC=$(/usr/bin/od -An -tx1 -j 56 -N 4 "$OUTPUT_PART" | /usr/bin/tr -d ' \n')
[ "$MAGIC" = 41524d64 ] || fail "VZ64 image has an invalid AArch64 header"
DECLARED_BYTES=$(/usr/bin/od -An -tu8 -j 16 -N 8 "$OUTPUT_PART" | /usr/bin/tr -d ' \n')
[ "$DECLARED_BYTES" -eq "$VZ_IMAGE_BYTES" ] ||
    fail "VZ64 header declares $DECLARED_BYTES bytes, expected $VZ_IMAGE_BYTES"

/bin/mv -- "$OUTPUT_PART" "$OUTPUT_IMAGE"
echo "Built $OUTPUT_IMAGE ($LINKED_IMAGE_BYTES-byte payload, $IMAGE_BYTES-byte image)"
