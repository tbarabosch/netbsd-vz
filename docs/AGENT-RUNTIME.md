# NetBSD guest agent and Apple Container runtime

## Architecture

The agent runtime is an external prototype alongside the EFI POC, not a nested
project and not a replacement boot path.

```text
container netbsd CLI
        |
        v
Apple Container API service
        | opaque NetBSDRuntimeData
        v
container-runtime-netbsd (one process per container)
        |
        +-- APFS CoW clone of the validated RAW base disk
        +-- persistent VZ machine identifier and EFI variable store
        +-- ttyVI00 -> append-only boot.log
        `-- ttyVI10 <-> NVZA protocol <-> root guest agent
```

The VM lifetime is owned by the runtime instance. The main process exiting,
an explicit stop, or a runtime teardown shuts the guest down and force-stops VZ
after a bounded grace period. The cloned root disk, machine identifier, and EFI
variables remain in the container bundle so a stopped instance can restart
with persistent guest state. The base RAW disk is never attached writable.

## Components

- `agent/` contains a statically linked NetBSD-native C daemon, its rc.d
  service, hardened guest configuration, and parser tests.
- `protocol/` contains the transport-independent v1 specification, C codec,
  Swift package, shared vectors, and fragmentation/malformed-frame tests.
- `runtime/` contains the Swift VZ runtime service, runtime client plugin, CLI
  plugin, entitlements, and runtime-data tests.
- `compat/` contains the focused Apache-2.0 Apple Container compatibility
  patch. Apple source headers and notices remain intact in that patch.

`make agent-disk` produces an image independently from `make disk`. It uses the
same stock EFI loader and `GENERIC64` kernel but installs the agent, disables
both gettys plus remote services, and locks root password authentication.

## Runtime data and compatibility branch

`NetBSDRuntimeData` schema v2 contains the immutable cached RAW-disk path and
SHA-512 plus the OCI image reference, manifest digest, platform-kit digest, and
assembler version. Schema v1 remains decodable for existing state. CPU and
memory remain normal `ContainerConfiguration` resources. Clone paths, EFI
state, and machine identity are runtime-private.

`make runtime-deps` checks out Apple Container 1.3.0 at the exact commit
`d6de5694200468d99a61662bfb9bb3aba763e3e5` into ignored build state and applies
`compat/apple-container-runtime-owned-resources.patch`. The patch adds the
generic `runtime-owned-resources` service capability, permits omitted
kernel/initfs/rootfs inputs for such runtimes, and leaves the legacy Linux
contract unchanged. The NetBSD service config declares that capability.

The checkout is used to compile the runtime client and CLI. Full `container`
integration also requires the running Apple Container API service to be built
from the same compatibility source. This repository deliberately does not
install or overwrite that daemon.

## OCI image path

`container netbsd create IMAGE --name NAME [options] [-- COMMAND ARG...]` and
`container netbsd run IMAGE --name NAME [options] [-- COMMAND ARG...]` fetch a
`netbsd/arm64` manifest through Apple's image store. The runtime accepts OCI or
Docker uncompressed, gzip, and zstd layers; verifies descriptor digests, sizes,
and config DiffIDs; applies whiteouts, hardlinks, ownership, modes, timestamps,
and symlinks; and rejects traversal, xattrs, devices, sockets, and FIFOs.

After untrusted layers are staged, the assembler injects the trusted GENERIC64
kernel, EFI loader/configuration, guest agent, locked login/service policy, and
`/dev` metadata. It produces a deterministic GPT disk with FAT32 ESP and FFSv1
root, then caches the read-only disk by manifest, platform-kit, agent,
assembler, and storage inputs. Runtime instances use APFS CoW clones.

`make oci-base` reproducibly converts SHA-512-pinned NetBSD 11.0 `base` and
`etc` sets into an OCI layout tagged `11.0` and `11`, with `netbsd/arm64`, root
user, `/`, `/bin/sh`, and the standard NetBSD environment. The agent, kernel,
and EFI assets remain outside the image.

## Supported v1 behavior

- bootstrap, state, process create/start/wait/delete
- concurrent processes with exact `execve` argv and explicit environment/cwd
- numeric or named OCI users/groups, supplemental groups, and supported NetBSD rlimits
- separate pipes or PTY, terminal resize, stdin close, signals, and wait
- output EOF before the final exit event
- persistent runtime logs and boot log
- recursive copy-in/out for files, directories, and symlinks
- traversal-resistant relative guest paths using `openat`/`fstatat` and
  `O_NOFOLLOW`
- graceful guest shutdown with a bounded VZ force-stop fallback

Statistics, networking, mounts, published ports/sockets, socket dialing,
Rosetta, Linux capabilities, cgroup controls, and sysctls return stable
unsupported errors in v1. No shell is inserted; shell syntax requires an
explicit `/bin/sh -c` argument vector.

## Serial transport

`ttyVI10` is configured raw and root-only. The frame format permits 64 KiB data
payloads, but NetBSD's current Virtio-console tty queue is roughly 1 KiB. The
serial adapter therefore sends 768-byte stdin/copy frames and waits for an ACK
after each. Control messages remain bounded at 1 MiB and are expected to stay
small in normal use. A future generic Virtio-vsock port can use the same runtime
and agent APIs with larger frames; serial remains the fallback.

## Verification

```sh
make test
make agent-disk
make runtime

.build/runtime/container-runtime-netbsd probe \
  --disk "$PWD/.build/out/netbsd-vz-agent.raw" \
  --state "$PWD/.build/probe" --timeout 120
```

`make test` runs the C and Swift protocol vectors, agent JSON parser regressions,
and runtime-data tests. The signed probe is the macOS/NetBSD integration test:
it checks boot/handshake, literal argv, environment/cwd/credentials/rlimits,
success and nonzero exits, concurrent execution, wait and EOF ordering, PTY
input/resize/signals, ACK-paced large binary stdin/stdout and stdin EOF, a
128 KiB file round-trip, recursive copy, an empty directory, file modes,
symlinks, and host-side traversal rejection.

Run the same probe command a second time without deleting `--state`. It reuses
the cloned guest disk, machine identifier, and EFI variable store and verifies
that a guest marker written during the first boot survived the restart. The
base RAW disk remains read-only to the runtime and is never attached to VZ.
