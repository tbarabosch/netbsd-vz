#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
WORK_ROOT="$REPO_ROOT/.build"
RUNNER_ROOT="$WORK_ROOT/bin"
RUNNER="$RUNNER_ROOT/netbsd-vz-runner"
RUNNER_SOURCE="$REPO_ROOT/runner/NetBSDVZRunner.swift"
ENTITLEMENTS="$REPO_ROOT/runner/netbsd-vz.entitlements"
DEFAULT_IMAGE="$WORK_ROOT/out/netbsd-VZ64-vz.img"
DEFAULT_DISK="$WORK_ROOT/out/netbsd-vz-root.raw"
RUN_ROOT="$WORK_ROOT/run"

usage()
{
    echo "usage: $0 [--disk NETBSD.RAW] [--network] [--smoke] [NETBSD.IMG]" >&2
}

DISK=
SMOKE=0
NETWORK=0
IMAGE=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --disk)
            [ "$#" -ge 2 ] || { echo "error: --disk requires a path" >&2; exit 1; }
            DISK=$2
            shift 2
            ;;
        --smoke)
            SMOKE=1
            shift
            ;;
        --network)
            NETWORK=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            echo "error: unknown option: $1" >&2
            usage
            exit 1
            ;;
        *)
            [ -z "$IMAGE" ] || { echo "error: only one kernel image may be specified" >&2; exit 1; }
            IMAGE=$1
            shift
            ;;
    esac
done

IMAGE=${IMAGE:-$DEFAULT_IMAGE}
[ "$SMOKE" -eq 0 ] || [ -n "$DISK" ] || {
    echo "error: --smoke requires --disk NETBSD.RAW" >&2
    exit 1
}

if [ -n "${NETBSD_VZ_TIMEOUT+x}" ]; then
    TIMEOUT=$NETBSD_VZ_TIMEOUT
elif [ -n "$DISK" ]; then
    TIMEOUT=90
else
    TIMEOUT=10
fi

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

/bin/mkdir -p "$RUNNER_ROOT"

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
TRANSCRIPT=
cleanup()
{
    if [ -n "$DISPOSABLE_DISK" ]; then
        /bin/rm -f -- "$DISPOSABLE_DISK"
    fi
}
interrupted()
{
    cleanup
    exit 130
}
trap cleanup EXIT
trap interrupted HUP INT TERM

if [ -n "$DISK" ]; then
    if [ "$DISK" = "$DEFAULT_DISK" ]; then
        [ -f "$DISK" ] || {
            echo "error: disk image is missing: $DISK" >&2
            exit 1
        }
        /bin/mkdir -p "$RUN_ROOT"
        DISPOSABLE_DISK="$RUN_ROOT/netbsd-vz-root.$$.raw"
        /bin/rm -f -- "$DISPOSABLE_DISK"
        /bin/cp -c "$DISK" "$DISPOSABLE_DISK"
        ATTACHED_DISK=$DISPOSABLE_DISK
        echo "Booting a disposable clone of $DISK" >&2
    elif [ ! -f "$DISK" ]; then
        echo "error: disk image is missing or not a regular file: $DISK" >&2
        exit 1
    fi
fi

set -- --timeout "$TIMEOUT"
[ -z "$ATTACHED_DISK" ] || set -- "$@" --disk "$ATTACHED_DISK"
[ "$NETWORK" -eq 0 ] || set -- "$@" --network
[ "$SMOKE" -eq 0 ] || set -- "$@" --smoke
set -- "$@" "$IMAGE"

if [ "$SMOKE" -eq 1 ]; then
    /bin/mkdir -p "$RUN_ROOT"
    TRANSCRIPT="$RUN_ROOT/smoke-console-$$.log"
    if NETBSD_VZ_TRANSCRIPT="$TRANSCRIPT" "$RUNNER" "$@"; then
        status=0
        /bin/rm -f -- "$TRANSCRIPT"
    else
        status=$?
        echo "Smoke console transcript preserved at $TRANSCRIPT" >&2
    fi
else
    if "$RUNNER" "$@"; then
        status=0
    else
        status=$?
    fi
fi

exit "$status"
