#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
WORK_ROOT="$REPO_ROOT/.build"
RUNNER_ROOT="$WORK_ROOT/bin"
RUNNER="$RUNNER_ROOT/netbsd-vz-runner"
RUNNER_SOURCE="$REPO_ROOT/runner/NetBSDVZRunner.swift"
ENTITLEMENTS="$REPO_ROOT/runner/netbsd-vz.entitlements"
DEFAULT_DISK="$WORK_ROOT/out/netbsd-vz.raw"
RUN_ROOT="$WORK_ROOT/run"

usage()
{
    echo "usage: $0 [--disk NETBSD.RAW] [--efi-state DIR] [--network]" >&2
}

DISK=$DEFAULT_DISK
EFI_STATE=
NETWORK=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --disk)
            [ "$#" -ge 2 ] || { echo "error: --disk requires a path" >&2; exit 1; }
            DISK=$2
            shift 2
            ;;
        --efi-state)
            [ "$#" -ge 2 ] || { echo "error: --efi-state requires a directory" >&2; exit 1; }
            EFI_STATE=$2
            shift 2
            ;;
        --network)
            NETWORK=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

TIMEOUT=${NETBSD_VZ_TIMEOUT:-120}
case "$TIMEOUT" in
    ''|*[!0-9]*|0)
        echo "error: NETBSD_VZ_TIMEOUT must be a positive integer" >&2
        exit 1
        ;;
esac

[ "$(/usr/bin/uname -s)" = Darwin ] || {
    echo "error: Virtualization.framework requires macOS" >&2
    exit 1
}
[ "$(/usr/bin/uname -m)" = arm64 ] || {
    echo "error: this proof requires Apple Silicon" >&2
    exit 1
}
[ -f "$DISK" ] || {
    echo "error: EFI disk image is missing: $DISK" >&2
    exit 1
}

/bin/mkdir -p "$RUNNER_ROOT" "$RUN_ROOT"
if [ ! -x "$RUNNER" ] || [ "$RUNNER_SOURCE" -nt "$RUNNER" ] ||
   [ "$ENTITLEMENTS" -nt "$RUNNER" ]; then
    echo "Compiling and signing the Virtualization.framework runner..."
    TEMP_RUNNER="$RUNNER.part"
    /bin/rm -f -- "$TEMP_RUNNER"
    /usr/bin/xcrun swiftc \
        -parse-as-library \
        -O \
        -framework Virtualization \
        "$RUNNER_SOURCE" \
        -o "$TEMP_RUNNER"
    /usr/bin/codesign \
        --force \
        --sign - \
        --timestamp=none \
        --entitlements "$ENTITLEMENTS" \
        "$TEMP_RUNNER"
    /bin/mv -- "$TEMP_RUNNER" "$RUNNER"
fi

ATTACHED_DISK=$DISK
DISPOSABLE_DISK=
DISPOSABLE_STATE=
cleanup()
{
    [ -z "$DISPOSABLE_DISK" ] || /bin/rm -f -- "$DISPOSABLE_DISK"
    [ -z "$DISPOSABLE_STATE" ] || /bin/rm -rf -- "$DISPOSABLE_STATE"
}
interrupted()
{
    cleanup
    exit 130
}
trap cleanup EXIT
trap interrupted HUP INT TERM

if [ "$DISK" = "$DEFAULT_DISK" ]; then
    DISPOSABLE_DISK="$RUN_ROOT/netbsd-vz.$$.raw"
    /bin/rm -f -- "$DISPOSABLE_DISK"
    /bin/cp -c "$DISK" "$DISPOSABLE_DISK"
    ATTACHED_DISK=$DISPOSABLE_DISK
    echo "Booting a disposable clone of $DISK" >&2
fi

if [ -z "$EFI_STATE" ]; then
    DISPOSABLE_STATE="$RUN_ROOT/efi-state.$$"
    /bin/rm -rf -- "$DISPOSABLE_STATE"
    EFI_STATE=$DISPOSABLE_STATE
fi
/bin/mkdir -p "$EFI_STATE"

set -- --timeout "$TIMEOUT" --disk "$ATTACHED_DISK" --efi-state "$EFI_STATE"
[ "$NETWORK" -eq 0 ] || set -- "$@" --network

"$RUNNER" "$@"
