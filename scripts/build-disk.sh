#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
WORK_ROOT="$REPO_ROOT/.build"
DOWNLOAD_ROOT="$WORK_ROOT/downloads"
DISK_ROOT="$WORK_ROOT/disk"
STAGING_ROOT="$DISK_ROOT/root"
WORK_DIR="$DISK_ROOT/work"
TOOLS_ROOT="$WORK_ROOT/tools/bin"
OUTPUT_ROOT="$WORK_ROOT/out"
OVERLAY_ROOT="$REPO_ROOT/rootfs-overlay"

NETBSD_VERSION=11.0
SETS_URL="https://cdn.netbsd.org/pub/NetBSD/NetBSD-${NETBSD_VERSION}/evbarm-aarch64/binary/sets"
BASE_SHA512=d17b3253959e110edba1755f481e707fd79a1a4a35bd7096a305c2959d6a5964713d4c35f439d76ca03d9252f8652d73f521ea6fc07a27ffa5ca22a80df6e7c5
ETC_SHA512=ff131eae576cf57112795321090d2b7f4148f2f61d4eff1a64ee4fe2f7f53e3b4b6e2aaf857b42a690e25611f9dd04adb7f0c2bdaa57000a1372416188c9a410
BASE_ARCHIVE="$DOWNLOAD_ROOT/NetBSD-${NETBSD_VERSION}-evbarm-aarch64-base.tar.xz"
ETC_ARCHIVE="$DOWNLOAD_ROOT/NetBSD-${NETBSD_VERSION}-evbarm-aarch64-etc.tar.xz"

DISK_BYTES=1073741824
SECTOR_BYTES=512
PARTITION_START=2048
PARTITION_SECTORS=2093056
PARTITION_LABEL=netbsd-root
PARTITION_BYTES=1071644672
OUTPUT_DISK="$OUTPUT_ROOT/netbsd-vz-root.raw"
SPEC_FILE="$DISK_ROOT/root.mtree"
STATE_FILE="$DISK_ROOT/.root-input-fingerprint"

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

sha512()
{
    /usr/bin/shasum -a 512 "$1" | /usr/bin/awk '{ print $1 }'
}

verify_archive()
{
    archive=$1
    expected=$2
    label=$3
    [ -f "$archive" ] || fail "$label is missing: $archive"
    actual=$(sha512 "$archive")
    [ "$actual" = "$expected" ] || fail "$label failed SHA-512 verification: $archive"
}

fetch_archive()
{
    name=$1
    expected=$2
    destination=$3
    label=$4
    if [ ! -f "$destination" ]; then
        echo "Downloading $label..."
        part="$destination.part"
        /bin/rm -f -- "$part"
        /usr/bin/curl --fail --location --retry 3 --output "$part" "$SETS_URL/$name"
        verify_archive "$part" "$expected" "$label"
        /bin/mv -- "$part" "$destination"
    fi
    verify_archive "$destination" "$expected" "$label"
}

require_executable()
{
    [ -x "$1" ] || fail "required executable not found: $1 (run make build first)"
}

fail_with_log()
{
    message=$1
    log=$2
    echo "error: $message" >&2
    /usr/bin/tail -n 40 "$log" >&2
    exit 1
}

case "$WORK_ROOT" in
    "$REPO_ROOT/.build") ;;
    *) fail "unexpected build workspace: $WORK_ROOT" ;;
esac

[ "$DISK_BYTES" -eq $((PARTITION_START * SECTOR_BYTES + PARTITION_BYTES + 2048 * SECTOR_BYTES)) ] ||
    fail "fixed disk geometry is internally inconsistent"
[ "$PARTITION_BYTES" -eq $((PARTITION_SECTORS * SECTOR_BYTES)) ] ||
    fail "fixed partition geometry is internally inconsistent"
[ "$(/usr/bin/uname -s)" = Darwin ] || fail "the disk builder requires macOS"
require_executable "$TOOLS_ROOT/nbgpt"
require_executable "$TOOLS_ROOT/nbmakefs"
require_executable /usr/bin/curl
require_executable /usr/bin/shasum
require_executable /usr/bin/tar

for overlay in fstab rc.conf ttys; do
    [ -f "$OVERLAY_ROOT/etc/$overlay" ] || fail "root overlay is missing etc/$overlay"
done

/bin/mkdir -p "$DOWNLOAD_ROOT" "$OUTPUT_ROOT" "$DISK_ROOT"
fetch_archive base.tar.xz "$BASE_SHA512" "$BASE_ARCHIVE" "NetBSD evbarm-aarch64 base set"
fetch_archive etc.tar.xz "$ETC_SHA512" "$ETC_ARCHIVE" "NetBSD evbarm-aarch64 etc set"

OVERLAY_FINGERPRINT=$(
    for overlay in fstab rc.conf ttys; do
        printf '%s  etc/%s\n' "$(sha512 "$OVERLAY_ROOT/etc/$overlay")" "$overlay"
    done | /usr/bin/shasum -a 512 | /usr/bin/awk '{ print $1 }'
)
INPUT_FINGERPRINT=$(printf '%s\n' \
    "$NETBSD_VERSION" "$BASE_SHA512" "$ETC_SHA512" "$OVERLAY_FINGERPRINT" \
    | /usr/bin/shasum -a 512 | /usr/bin/awk '{ print $1 }')

CACHED_FINGERPRINT=
if [ -f "$STATE_FILE" ]; then
    CACHED_FINGERPRINT=$(/bin/cat "$STATE_FILE")
fi
if [ "$CACHED_FINGERPRINT" != "$INPUT_FINGERPRINT" ]; then
    echo "Assembling the verified minimal NetBSD root tree..."
    if [ -d "$STAGING_ROOT/var/spool/ftp/hidden" ]; then
        /bin/chmod u+rwx "$STAGING_ROOT/var/spool/ftp/hidden"
    fi
    safe_remove "$STAGING_ROOT"
    safe_remove "$WORK_DIR"
    /bin/rm -f -- "$SPEC_FILE" "$STATE_FILE"
    /bin/mkdir -p "$STAGING_ROOT" "$WORK_DIR"
    /usr/bin/tar -xJf "$BASE_ARCHIVE" -C "$STAGING_ROOT"
    /usr/bin/tar -xJf "$ETC_ARCHIVE" -C "$STAGING_ROOT"
    for overlay in fstab rc.conf ttys; do
        /bin/cp -p "$OVERLAY_ROOT/etc/$overlay" "$STAGING_ROOT/etc/$overlay"
    done

    /bin/cat "$STAGING_ROOT"/etc/mtree/* |
        /usr/bin/sed -E 's/ size=[0-9]+//' > "$SPEC_FILE"
    (
        cd "$STAGING_ROOT/dev"
        /bin/sh ./MAKEDEV -s all ipty
    ) | /usr/bin/sed -e '/^\. type=dir/d' -e 's,^\.,./dev,' >> "$SPEC_FILE"
    printf '%s\n' "$INPUT_FINGERPRINT" > "$STATE_FILE"
else
    echo "Reusing assembled root tree from $STAGING_ROOT"
    /bin/mkdir -p "$WORK_DIR"
fi

for required in sbin/init bin/sh usr/libexec/getty etc/rc; do
    [ -f "$STAGING_ROOT/$required" ] || fail "root tree is missing /$required"
done
/usr/bin/grep -q '^\./dev/console[[:space:]]' "$SPEC_FILE" || fail "device manifest is missing /dev/console"
/usr/bin/grep -q '^\./dev/constty[[:space:]]' "$SPEC_FILE" || fail "device manifest is missing /dev/constty"
/usr/bin/grep -q '^\./dev/ttyVI00[[:space:]]' "$SPEC_FILE" || fail "device manifest is missing Virtio console nodes"
/usr/bin/grep -q '^\./dev/ld0a[[:space:]]' "$SPEC_FILE" || fail "device manifest is missing ld nodes"
/usr/bin/grep -q '^\./dev/dk0[[:space:]]' "$SPEC_FILE" || fail "device manifest is missing dk nodes"
/usr/bin/grep -q '^root::' "$STAGING_ROOT/etc/master.passwd" || fail "release set no longer has the expected empty root password"

ROOTFS_PART="$WORK_DIR/root.ffs.part"
GPT_TEMPLATE="$WORK_DIR/gpt-template.raw"
OUTPUT_PART="$OUTPUT_DISK.part"
safe_remove "$ROOTFS_PART"
safe_remove "$GPT_TEMPLATE"
safe_remove "$OUTPUT_PART"

echo "Creating fixed-size little-endian FFSv1 root filesystem..."
# The FTP hidden directory is intentionally execute-only in the release set.
# Let makefs inventory it, then restore the staged tree's release mode even if
# image creation fails.
FTP_HIDDEN="$STAGING_ROOT/var/spool/ftp/hidden"
restore_hidden_mode()
{
    [ ! -d "$FTP_HIDDEN" ] || /bin/chmod 0111 "$FTP_HIDDEN"
}
/bin/chmod u+r "$FTP_HIDDEN"
trap restore_hidden_mode EXIT
MAKEFS_LOG="$WORK_DIR/makefs.log"
if ! "$TOOLS_ROOT/nbmakefs" \
    -Z -B little -s "$PARTITION_BYTES" -S "$SECTOR_BYTES" \
    -F "$SPEC_FILE" -N "$STAGING_ROOT/etc" -t ffs \
    -o "version=1,bsize=16384,fsize=2048,density=8192,label=$PARTITION_LABEL" \
    "$ROOTFS_PART" "$STAGING_ROOT" >"$MAKEFS_LOG" 2>&1; then
    restore_hidden_mode
    fail_with_log "FFS image creation failed; log: $MAKEFS_LOG" "$MAKEFS_LOG"
fi
restore_hidden_mode
trap - EXIT

echo "Wrapping root filesystem in the fixed GPT layout..."
/usr/bin/truncate -s "$DISK_BYTES" "$GPT_TEMPLATE"
GPT_LOG="$WORK_DIR/gpt.log"
if ! "$TOOLS_ROOT/nbgpt" -T 1700000000 "$GPT_TEMPLATE" create \
    >"$GPT_LOG" 2>&1; then
    fail_with_log "GPT creation failed; log: $GPT_LOG" "$GPT_LOG"
fi
if ! "$TOOLS_ROOT/nbgpt" -T 1700000001 "$GPT_TEMPLATE" add \
    -b "$PARTITION_START" -s "$PARTITION_SECTORS" -i 1 \
    -l "$PARTITION_LABEL" -t ffs >>"$GPT_LOG" 2>&1; then
    fail_with_log "GPT partition creation failed; log: $GPT_LOG" "$GPT_LOG"
fi
/bin/cp -c "$GPT_TEMPLATE" "$OUTPUT_PART"
/bin/dd if="$ROOTFS_PART" of="$OUTPUT_PART" bs="$SECTOR_BYTES" \
    seek="$PARTITION_START" conv=notrunc >/dev/null 2>&1
[ "$(/usr/bin/stat -f %z "$OUTPUT_PART")" -eq "$DISK_BYTES" ] || fail "disk assembly produced the wrong size"
/bin/mv -- "$OUTPUT_PART" "$OUTPUT_DISK"

safe_remove "$ROOTFS_PART"
safe_remove "$GPT_TEMPLATE"
echo "Built $OUTPUT_DISK"
