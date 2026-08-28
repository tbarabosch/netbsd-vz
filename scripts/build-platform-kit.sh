#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
WORK_ROOT="$REPO_ROOT/.build"
DOWNLOAD_ROOT="$WORK_ROOT/downloads"
KIT_ROOT="$WORK_ROOT/platform-kit/root"
KIT_WORK="$WORK_ROOT/platform-kit/work"
OUTPUT_ROOT="$WORK_ROOT/out"
ARCHIVE="$OUTPUT_ROOT/netbsd-vz-platform-kit-11.0-1-darwin-arm64.tar.xz"
BASE_ARCHIVE="$DOWNLOAD_ROOT/NetBSD-11.0-evbarm-aarch64-base.tar.xz"
BASE_URL=https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/evbarm-aarch64/binary/sets/base.tar.xz
BASE_SHA512=d17b3253959e110edba1755f481e707fd79a1a4a35bd7096a305c2959d6a5964713d4c35f439d76ca03d9252f8652d73f521ea6fc07a27ffa5ca22a80df6e7c5

fail() { echo "error: $*" >&2; exit 1; }
sha512() { /usr/bin/shasum -a 512 "$1" | /usr/bin/awk '{print $1}'; }
safe_remove()
{
    case "$1" in "$WORK_ROOT"/*) /bin/rm -rf -- "$1" ;; *) fail "unsafe path: $1" ;; esac
}

[ "$(/usr/bin/uname -s)" = Darwin ] || fail "platform kit requires macOS"
[ "$(/usr/bin/uname -m)" = arm64 ] || fail "platform kit requires Apple Silicon"
[ -f "$OUTPUT_ROOT/netbsd-GENERIC64" ] || fail "run make build first"
[ -d "$WORK_ROOT/tools/bin" ] || fail "NetBSD tools are missing"
/bin/mkdir -p "$DOWNLOAD_ROOT" "$OUTPUT_ROOT"
if [ ! -f "$BASE_ARCHIVE" ]; then
    /usr/bin/curl --fail --location --retry 3 --output "$BASE_ARCHIVE.part" "$BASE_URL"
    [ "$(sha512 "$BASE_ARCHIVE.part")" = "$BASE_SHA512" ] || fail "base set checksum mismatch"
    /bin/mv "$BASE_ARCHIVE.part" "$BASE_ARCHIVE"
fi
[ "$(sha512 "$BASE_ARCHIVE")" = "$BASE_SHA512" ] || fail "base set checksum mismatch"

safe_remove "$KIT_ROOT"
safe_remove "$KIT_WORK"
/bin/mkdir -p "$KIT_ROOT/kernel" "$KIT_ROOT/EFI/BOOT" "$KIT_WORK/extract"
/bin/cp "$OUTPUT_ROOT/netbsd-GENERIC64" "$KIT_ROOT/kernel/netbsd-GENERIC64"
/bin/cp "$REPO_ROOT/efi/boot.cfg" "$KIT_ROOT/EFI/BOOT/boot.cfg"
/usr/bin/tar -xJf "$BASE_ARCHIVE" -C "$KIT_WORK/extract" ./usr/mdec/bootaa64.efi
/bin/cp "$KIT_WORK/extract/usr/mdec/bootaa64.efi" "$KIT_ROOT/EFI/BOOT/BOOTAA64.EFI"
/bin/cp -cR "$WORK_ROOT/tools" "$KIT_ROOT/tools"

(
    cd "$KIT_ROOT"
    /usr/bin/find . -type f ! -name tools.sha512 ! -name platform-kit.json -print |
        LC_ALL=C /usr/bin/sort |
        /usr/bin/xargs -n 128 /usr/bin/shasum -a 512 >tools.sha512
)
TOOLS_MANIFEST_SHA512=$(sha512 "$KIT_ROOT/tools.sha512")
KERNEL_SHA512=$(sha512 "$KIT_ROOT/kernel/netbsd-GENERIC64")
EFI_SHA512=$(sha512 "$KIT_ROOT/EFI/BOOT/BOOTAA64.EFI")
BOOT_CONFIG_SHA512=$(sha512 "$KIT_ROOT/EFI/BOOT/boot.cfg")
SOURCE_FINGERPRINT=unknown
[ ! -f "$WORK_ROOT/source/.netbsd-vz-source-fingerprint" ] || SOURCE_FINGERPRINT=$(/bin/cat "$WORK_ROOT/source/.netbsd-vz-source-fingerprint")

{
    printf '%s\n' '{'
    printf '%s\n' '  "schemaVersion": 1,'
    printf '%s\n' '  "netbsdVersion": "11.0",'
    printf '%s\n' '  "hostPlatform": "darwin/arm64",'
    printf '%s\n' '  "guestPlatform": "netbsd/arm64",'
    printf '  "sourceFingerprint": "%s",\n' "$SOURCE_FINGERPRINT"
    printf '  "kernelSHA512": "%s",\n' "$KERNEL_SHA512"
    printf '  "efiLoaderSHA512": "%s",\n' "$EFI_SHA512"
    printf '  "bootConfigSHA512": "%s",\n' "$BOOT_CONFIG_SHA512"
    printf '  "filesManifestSHA512": "%s"\n' "$TOOLS_MANIFEST_SHA512"
    printf '%s\n' '}'
} >"$KIT_ROOT/platform-kit.json"

/usr/bin/find "$KIT_ROOT" -exec /usr/bin/touch -h -t 202311142213.20 {} +
(
    cd "$KIT_ROOT"
    /usr/bin/find . -print | LC_ALL=C /usr/bin/sort >"$KIT_WORK/files.list"
    /usr/bin/tar -cJf "$ARCHIVE.part" --no-recursion --uid 0 --gid 0 --uname root --gname wheel \
        -T "$KIT_WORK/files.list"
)
/bin/mv "$ARCHIVE.part" "$ARCHIVE"
sha512 "$ARCHIVE" >"$ARCHIVE.sha512"
echo "Built $ARCHIVE"
