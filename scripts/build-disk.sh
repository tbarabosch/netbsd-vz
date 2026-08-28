#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
WORK_ROOT="$REPO_ROOT/.build"
DOWNLOAD_ROOT="$WORK_ROOT/downloads"
AGENT_DISK=${NETBSD_VZ_AGENT_DISK:-0}
case "$AGENT_DISK" in
    0|1) ;;
    *) echo "error: NETBSD_VZ_AGENT_DISK must be 0 or 1" >&2; exit 1 ;;
esac
if [ "$AGENT_DISK" -eq 1 ]; then
    DISK_ROOT="$WORK_ROOT/agent-disk"
    OUTPUT_NAME=netbsd-vz-agent.raw
    OVERLAY_ROOT="$REPO_ROOT/agent/rootfs-overlay"
    AGENT_BINARY="$WORK_ROOT/out/netbsd-vz-agent"
else
    DISK_ROOT="$WORK_ROOT/disk"
    OUTPUT_NAME=netbsd-vz.raw
    OVERLAY_ROOT="$REPO_ROOT/rootfs-overlay"
    AGENT_BINARY=
fi
STAGING_ROOT="$DISK_ROOT/root"
ESP_ROOT="$DISK_ROOT/esp"
WORK_DIR="$DISK_ROOT/work"
TOOLS_ROOT="$WORK_ROOT/tools/bin"
OUTPUT_ROOT="$WORK_ROOT/out"
OUTPUT_KERNEL="$OUTPUT_ROOT/netbsd-GENERIC64"
OUTPUT_DISK="$OUTPUT_ROOT/$OUTPUT_NAME"
BOOT_CONFIG="$REPO_ROOT/efi/boot.cfg"
SPEC_FILE="$DISK_ROOT/root.mtree"
STATE_FILE="$DISK_ROOT/.root-input-fingerprint"

NETBSD_VERSION=11.0
SETS_URL="https://cdn.netbsd.org/pub/NetBSD/NetBSD-$NETBSD_VERSION/evbarm-aarch64/binary/sets"
BASE_SHA512=d17b3253959e110edba1755f481e707fd79a1a4a35bd7096a305c2959d6a5964713d4c35f439d76ca03d9252f8652d73f521ea6fc07a27ffa5ca22a80df6e7c5
ETC_SHA512=ff131eae576cf57112795321090d2b7f4148f2f61d4eff1a64ee4fe2f7f53e3b4b6e2aaf857b42a690e25611f9dd04adb7f0c2bdaa57000a1372416188c9a410
BASE_ARCHIVE="$DOWNLOAD_ROOT/NetBSD-$NETBSD_VERSION-evbarm-aarch64-base.tar.xz"
ETC_ARCHIVE="$DOWNLOAD_ROOT/NetBSD-$NETBSD_VERSION-evbarm-aarch64-etc.tar.xz"

DISK_BYTES=1140850688
SECTOR_BYTES=512
ESP_START=2048
ESP_SECTORS=131072
ESP_BYTES=67108864
ROOT_START=133120
ROOT_SECTORS=2093056
ROOT_BYTES=1071644672
ROOT_LABEL=netbsd-root

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
    /usr/bin/shasum -a 512 "$1" | /usr/bin/awk '{print $1}'
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
    /usr/bin/tail -n 60 "$log" >&2
    exit 1
}

case "$WORK_ROOT" in
    "$REPO_ROOT/.build") ;;
    *) fail "unexpected build workspace: $WORK_ROOT" ;;
esac

[ "$ESP_BYTES" -eq $((ESP_SECTORS * SECTOR_BYTES)) ] ||
    fail "ESP geometry is internally inconsistent"
[ "$ROOT_BYTES" -eq $((ROOT_SECTORS * SECTOR_BYTES)) ] ||
    fail "root geometry is internally inconsistent"
[ "$ROOT_START" -eq $((ESP_START + ESP_SECTORS)) ] ||
    fail "ESP and root partitions are not contiguous"
[ "$DISK_BYTES" -eq $(((ROOT_START + ROOT_SECTORS + 2048) * SECTOR_BYTES)) ] ||
    fail "disk geometry is internally inconsistent"
[ "$(/usr/bin/uname -s)" = Darwin ] || fail "the disk builder requires macOS"
require_executable "$TOOLS_ROOT/nbgpt"
require_executable "$TOOLS_ROOT/nbmakefs"
require_executable /usr/bin/curl
require_executable /usr/bin/shasum
require_executable /usr/bin/tar
[ "$AGENT_DISK" -eq 0 ] || require_executable "$TOOLS_ROOT/nbpwd_mkdb"
[ -f "$OUTPUT_KERNEL" ] || fail "GENERIC64 is missing; run make build first"
[ -f "$BOOT_CONFIG" ] || fail "EFI boot configuration is missing: $BOOT_CONFIG"
[ "$AGENT_DISK" -eq 0 ] || [ -x "$AGENT_BINARY" ] || fail "agent is missing; run make agent first"

for overlay in fstab rc.conf ttys; do
    [ -f "$OVERLAY_ROOT/etc/$overlay" ] || fail "root overlay is missing etc/$overlay"
done

/bin/mkdir -p "$DOWNLOAD_ROOT" "$OUTPUT_ROOT" "$DISK_ROOT"
fetch_archive base.tar.xz "$BASE_SHA512" "$BASE_ARCHIVE" "NetBSD evbarm-aarch64 base set"
fetch_archive etc.tar.xz "$ETC_SHA512" "$ETC_ARCHIVE" "NetBSD evbarm-aarch64 etc set"

OVERLAY_FINGERPRINT=$(
    {
        for overlay in fstab rc.conf ttys; do
            printf '%s  etc/%s\n' "$(sha512 "$OVERLAY_ROOT/etc/$overlay")" "$overlay"
        done
        if [ "$AGENT_DISK" -eq 1 ]; then
            printf '%s  etc/rc.d/netbsd_vz_agent\n' "$(sha512 "$OVERLAY_ROOT/etc/rc.d/netbsd_vz_agent")"
            printf '%s  usr/sbin/netbsd-vz-agent\n' "$(sha512 "$AGENT_BINARY")"
        fi
    } | /usr/bin/shasum -a 512 | /usr/bin/awk '{print $1}'
)
INPUT_FINGERPRINT=$(printf '%s\n' "$NETBSD_VERSION" "$BASE_SHA512" "$ETC_SHA512" "$AGENT_DISK" "$OVERLAY_FINGERPRINT" |
    /usr/bin/shasum -a 512 | /usr/bin/awk '{print $1}')

CACHED_FINGERPRINT=
if [ -f "$STATE_FILE" ]; then
    CACHED_FINGERPRINT=$(/bin/cat "$STATE_FILE")
fi
if [ "$CACHED_FINGERPRINT" != "$INPUT_FINGERPRINT" ]; then
    echo "Assembling the verified NetBSD 11.0 root tree..."
    if [ -d "$STAGING_ROOT/var/spool/ftp/hidden" ]; then
        /bin/chmod u+rwx "$STAGING_ROOT/var/spool/ftp/hidden"
    fi
    safe_remove "$STAGING_ROOT"
    safe_remove "$ESP_ROOT"
    safe_remove "$WORK_DIR"
    /bin/rm -f -- "$SPEC_FILE" "$STATE_FILE"
    /bin/mkdir -p "$STAGING_ROOT" "$WORK_DIR"
    /usr/bin/tar -xJf "$BASE_ARCHIVE" -C "$STAGING_ROOT"
    /usr/bin/tar -xJf "$ETC_ARCHIVE" -C "$STAGING_ROOT"
    for overlay in fstab rc.conf ttys; do
        /bin/cp -p "$OVERLAY_ROOT/etc/$overlay" "$STAGING_ROOT/etc/$overlay"
    done
    if [ "$AGENT_DISK" -eq 1 ]; then
        /usr/bin/install -m 0555 "$AGENT_BINARY" "$STAGING_ROOT/usr/sbin/netbsd-vz-agent"
        /usr/bin/install -m 0555 "$OVERLAY_ROOT/etc/rc.d/netbsd_vz_agent" "$STAGING_ROOT/etc/rc.d/netbsd_vz_agent"
        /usr/bin/sed -E 's/^root:[^:]*:/root:*:/' "$STAGING_ROOT/etc/master.passwd" > "$WORK_DIR/master.passwd"
        "$TOOLS_ROOT/nbpwd_mkdb" -L -p -d "$STAGING_ROOT" "$WORK_DIR/master.passwd"
    fi

    /bin/cat "$STAGING_ROOT"/etc/mtree/* |
        /usr/bin/sed -E 's/ size=[0-9]+//' > "$SPEC_FILE"
    if [ "$AGENT_DISK" -eq 1 ]; then
        printf '%s\n' \
            './etc/rc.d/netbsd_vz_agent type=file mode=0555 uid=0 gid=0' \
            './usr/sbin/netbsd-vz-agent type=file mode=0555 uid=0 gid=0' >> "$SPEC_FILE"
    fi
    (
        cd "$STAGING_ROOT/dev"
        /bin/sh ./MAKEDEV -s all ipty
    ) | /usr/bin/sed -e '/^\. type=dir/d' -e 's,^\.,./dev,' >> "$SPEC_FILE"
    printf '%s\n' "$INPUT_FINGERPRINT" > "$STATE_FILE"
else
    echo "Reusing assembled root tree from $STAGING_ROOT"
    /bin/mkdir -p "$WORK_DIR"
fi

for required in sbin/init bin/sh usr/libexec/getty etc/rc usr/mdec/bootaa64.efi; do
    [ -f "$STAGING_ROOT/$required" ] || fail "root tree is missing /$required"
done
/usr/bin/grep -q '^\./dev/ttyVI00[[:space:]]' "$SPEC_FILE" ||
    fail "device manifest is missing Virtio console nodes"
/usr/bin/grep -q '^\./dev/dk0[[:space:]]' "$SPEC_FILE" ||
    fail "device manifest is missing dk nodes"
if [ "$AGENT_DISK" -eq 1 ]; then
    /usr/bin/grep -q '^root:\*:' "$STAGING_ROOT/etc/master.passwd" ||
        fail "agent image does not lock root password login"
    /usr/bin/grep -q '^ttyVI00.*off secure' "$STAGING_ROOT/etc/ttys" ||
        fail "agent image unexpectedly enables ttyVI00 login"
    /usr/bin/grep -q '^ttyVI10.*off secure' "$STAGING_ROOT/etc/ttys" ||
        fail "agent image unexpectedly enables ttyVI10 login"
else
    /usr/bin/grep -q '^root::' "$STAGING_ROOT/etc/master.passwd" ||
        fail "release set no longer has the expected empty root password"
    /usr/bin/grep -q '^ttyVI00.*on secure' "$STAGING_ROOT/etc/ttys" ||
        fail "root does not enable ttyVI00"
fi

/bin/cp -p "$OUTPUT_KERNEL" "$STAGING_ROOT/netbsd"
safe_remove "$ESP_ROOT"
/bin/mkdir -p "$ESP_ROOT/EFI/BOOT"
/bin/cp "$STAGING_ROOT/usr/mdec/bootaa64.efi" "$ESP_ROOT/EFI/BOOT/BOOTAA64.EFI"
/bin/cp "$BOOT_CONFIG" "$ESP_ROOT/EFI/BOOT/boot.cfg"

/usr/bin/file "$STAGING_ROOT/netbsd" | /usr/bin/grep -q 'ELF 64-bit.*ARM aarch64' ||
    fail "/netbsd is not an AArch64 ELF kernel"
/usr/bin/file "$ESP_ROOT/EFI/BOOT/BOOTAA64.EFI" |
    /usr/bin/grep -q 'PE32+ executable.*Aarch64' ||
    fail "BOOTAA64.EFI is not an AArch64 EFI application"

ROOTFS_PART="$WORK_DIR/root.ffs.part"
ESP_PART="$WORK_DIR/esp.fat.part"
GPT_TEMPLATE="$WORK_DIR/gpt-template.raw"
OUTPUT_PART="$OUTPUT_DISK.part"
for target in "$ROOTFS_PART" "$ESP_PART" "$GPT_TEMPLATE" "$OUTPUT_PART"; do
    safe_remove "$target"
done

FTP_HIDDEN="$STAGING_ROOT/var/spool/ftp/hidden"
restore_hidden_mode()
{
    [ ! -d "$FTP_HIDDEN" ] || /bin/chmod 0111 "$FTP_HIDDEN"
}
/bin/chmod u+r "$FTP_HIDDEN"
trap restore_hidden_mode EXIT

echo "Creating fixed-size little-endian FFSv1 root filesystem..."
ROOTFS_LOG="$WORK_DIR/makefs-root.log"
if ! "$TOOLS_ROOT/nbmakefs" -Z -B little -s "$ROOT_BYTES" -S "$SECTOR_BYTES" -F "$SPEC_FILE" -N "$STAGING_ROOT/etc" -t ffs -o "version=1,bsize=16384,fsize=2048,density=8192,label=$ROOT_LABEL" "$ROOTFS_PART" "$STAGING_ROOT" >"$ROOTFS_LOG" 2>&1; then
    restore_hidden_mode
    fail_with_log "FFS image creation failed; log: $ROOTFS_LOG" "$ROOTFS_LOG"
fi
restore_hidden_mode
trap - EXIT

echo "Creating 64 MiB FAT32 EFI System Partition..."
ESP_LOG="$WORK_DIR/makefs-esp.log"
if ! "$TOOLS_ROOT/nbmakefs" -Z -s "$ESP_BYTES" -S "$SECTOR_BYTES" -T 1700000002 -t msdos -o "F=32,c=1,L=NETBSD_EFI" "$ESP_PART" "$ESP_ROOT" >"$ESP_LOG" 2>&1; then
    fail_with_log "ESP creation failed; log: $ESP_LOG" "$ESP_LOG"
fi

echo "Wrapping ESP and root filesystem in GPT..."
/usr/bin/truncate -s "$DISK_BYTES" "$GPT_TEMPLATE"
GPT_LOG="$WORK_DIR/gpt.log"
if ! "$TOOLS_ROOT/nbgpt" -T 1700000000 "$GPT_TEMPLATE" create >"$GPT_LOG" 2>&1; then
    fail_with_log "GPT creation failed; log: $GPT_LOG" "$GPT_LOG"
fi
if ! "$TOOLS_ROOT/nbgpt" -T 1700000001 "$GPT_TEMPLATE" add -b "$ESP_START" -s "$ESP_SECTORS" -i 1 -l netbsd-esp -t efi >>"$GPT_LOG" 2>&1; then
    fail_with_log "ESP GPT entry creation failed; log: $GPT_LOG" "$GPT_LOG"
fi
if ! "$TOOLS_ROOT/nbgpt" -T 1700000002 "$GPT_TEMPLATE" add -b "$ROOT_START" -s "$ROOT_SECTORS" -i 2 -l "$ROOT_LABEL" -t ffs >>"$GPT_LOG" 2>&1; then
    fail_with_log "root GPT entry creation failed; log: $GPT_LOG" "$GPT_LOG"
fi

/bin/cp -c "$GPT_TEMPLATE" "$OUTPUT_PART"
/bin/dd if="$ESP_PART" of="$OUTPUT_PART" bs="$SECTOR_BYTES" seek="$ESP_START" conv=notrunc >/dev/null 2>&1
/bin/dd if="$ROOTFS_PART" of="$OUTPUT_PART" bs="$SECTOR_BYTES" seek="$ROOT_START" conv=notrunc >/dev/null 2>&1
[ "$(/usr/bin/stat -f %z "$OUTPUT_PART")" -eq "$DISK_BYTES" ] ||
    fail "EFI disk assembly produced the wrong size"

GPT_VIEW=$("$TOOLS_ROOT/nbgpt" "$OUTPUT_PART" show -l)
printf '%s\n' "$GPT_VIEW" | /usr/bin/grep -q 'netbsd-esp' ||
    fail "assembled GPT does not contain the ESP label"
printf '%s\n' "$GPT_VIEW" | /usr/bin/grep -q "$ROOT_LABEL" ||
    fail "assembled GPT does not contain the root label"
/bin/mv -- "$OUTPUT_PART" "$OUTPUT_DISK"

safe_remove "$ROOTFS_PART"
safe_remove "$ESP_PART"
safe_remove "$GPT_TEMPLATE"
echo "Built $OUTPUT_DISK"
