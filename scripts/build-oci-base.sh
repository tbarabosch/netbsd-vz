#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
WORK_ROOT="$REPO_ROOT/.build"
DOWNLOAD_ROOT="$WORK_ROOT/downloads"
OUTPUT_ROOT="$WORK_ROOT/out"
LAYOUT="$OUTPUT_ROOT/netbsd-oci-layout"
ARCHIVE="$OUTPUT_ROOT/netbsd-oci-netbsd-11.0.tar"
BASE="$DOWNLOAD_ROOT/NetBSD-11.0-evbarm-aarch64-base.tar.xz"
ETC="$DOWNLOAD_ROOT/NetBSD-11.0-evbarm-aarch64-etc.tar.xz"
SETS_URL=https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/evbarm-aarch64/binary/sets
BASE_SHA512=d17b3253959e110edba1755f481e707fd79a1a4a35bd7096a305c2959d6a5964713d4c35f439d76ca03d9252f8652d73f521ea6fc07a27ffa5ca22a80df6e7c5
ETC_SHA512=ff131eae576cf57112795321090d2b7f4148f2f61d4eff1a64ee4fe2f7f53e3b4b6e2aaf857b42a690e25611f9dd04adb7f0c2bdaa57000a1372416188c9a410

fail() { echo "error: $*" >&2; exit 1; }
sha512() { /usr/bin/shasum -a 512 "$1" | /usr/bin/awk '{print $1}'; }
fetch()
{
    name=$1 expected=$2 output=$3
    if [ ! -f "$output" ]; then
        /usr/bin/curl --fail --location --retry 3 --output "$output.part" "$SETS_URL/$name"
        [ "$(sha512 "$output.part")" = "$expected" ] || fail "$name checksum mismatch"
        /bin/mv "$output.part" "$output"
    fi
    [ "$(sha512 "$output")" = "$expected" ] || fail "$name checksum mismatch"
}

/bin/mkdir -p "$DOWNLOAD_ROOT" "$OUTPUT_ROOT"
fetch base.tar.xz "$BASE_SHA512" "$BASE"
fetch etc.tar.xz "$ETC_SHA512" "$ETC"
case "$LAYOUT" in "$WORK_ROOT"/*) /bin/rm -rf -- "$LAYOUT" ;; *) fail "unsafe layout path" ;; esac
/bin/rm -f -- "$ARCHIVE" "$ARCHIVE.sha512"
"$WORK_ROOT/runtime/netbsd-oci-base" --base "$BASE" --etc "$ETC" --output "$LAYOUT"
/usr/bin/find "$LAYOUT" -exec /usr/bin/touch -h -t 202311142213.20 {} +
(
    cd "$LAYOUT"
    /usr/bin/find . -print | LC_ALL=C /usr/bin/sort >"$OUTPUT_ROOT/netbsd-oci-files.list"
    /usr/bin/tar -cf "$ARCHIVE" --no-recursion --uid 0 --gid 0 --uname root --gname wheel \
        -T "$OUTPUT_ROOT/netbsd-oci-files.list"
)
sha512 "$ARCHIVE" >"$ARCHIVE.sha512"
echo "Built OCI layout $LAYOUT and archive $ARCHIVE"
