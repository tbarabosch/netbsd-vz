# NetBSD 11 EFI boot on Apple Virtualization.framework

This proof of concept builds and boots NetBSD 11.0/evbarm-aarch64 on an
Apple Silicon Mac through Virtualization.framework's generic EFI platform.
It uses the stock NetBSD `bootaa64.efi` loader and stock `GENERIC64` kernel
configuration.

The repository temporarily contains the NetBSD guest agent, OCI disk
assembler, and external Apple Container runtime while their contracts are
validated. They will move to
[`container-runtime-netbsd`](https://github.com/tbarabosch/container-runtime-netbsd);
the EFI POC image, runner, console login, RAW-disk tools, patches, and platform
kit producer remain here.

The only NetBSD source changes are three generic Virtio fixes: PCI memory
decoding, reset-completion waiting, and network MTU negotiation. There is no
VZ-specific kernel configuration or fallback to
[the earlier direct-boot implementation](https://tbarabosch.com/porting-netbsd-to-apple-vz/).

![Condensed terminal transcript of NetBSD 11 booting through EFI on Apple VZ and shutting down cleanly](docs/netbsd-vz-boot.gif)

_Condensed from an actual offline `make run` EFI boot. Machine-local paths
and repetitive output are omitted._

## Requirements

- Apple Silicon Mac with Virtualization.framework
- Xcode or Xcode Command Line Tools selected with `xcode-select`
- `make` and network access to the official NetBSD archives
- About 10 GiB of free space for source, tools, objects, and images

The first build downloads SHA-512-pinned NetBSD 11.0 source sets and builds
the NetBSD AArch64 cross-tools locally.

## Why EFI instead of our earlier direct-boot work?

EFI follows NetBSD's normal arm64 boot contract: firmware loads the stock
`bootaa64.efi` from a GPT disk, and the loader starts stock `GENERIC64` using
ACPI hardware discovery. [Our earlier direct-boot
work](https://tbarabosch.com/porting-netbsd-to-apple-vz/) instead required a
raw AArch64 Image, an FDT supplied by the host, and changes around bootstrap
and console selection.

For this project, EFI is superior because the goal is the smallest possible
upstream NetBSD change. It removes the VZ-specific loader, FDT, raw-image,
and forced-console delta, leaving only generic Virtio driver fixes. EFI does
require an EFI System Partition, variable-store state, and a Virtio GPU for
GOP, and it can take longer to boot; the earlier approach can still be useful
when a small, firmware-free boot path matters more than matching normal
hardware.

## Build and run

```sh
make build
make disk

make run
make run-network
make clean
```

`make run` boots without a network device. `make run-network` adds a Virtio
network device attached to VZ NAT.

The default disk is copy-on-write cloned for each run, and EFI state is
temporary. Passing another disk attaches it directly; passing an EFI-state
directory reuses the machine identifier and EFI variable store.

## Output and overrides

```text
.build/out/netbsd-GENERIC64
.build/out/netbsd-vz.raw
.build/out/netbsd-vz-agent
.build/out/netbsd-vz-agent.raw
.build/runtime/container-runtime-netbsd
.build/runtime/netbsd
```

`netbsd-vz.raw` is a 1,088 MiB GPT disk. It contains a 64 MiB FAT32 EFI
System Partition followed by an FFSv1 root partition named `netbsd-root`.

```sh
NETBSD_VZ_JOBS=8 make build
NETBSD_VZ_TIMEOUT=180 make run
DISK=/absolute/path/netbsd.raw make run
./scripts/run.sh --disk /absolute/path/netbsd.raw \
    --efi-state /absolute/path/efi-state
```

The runner always uses EFI. There is deliberately no boot-mode selector.

## Guest agent and Apple Container runtime

Build the separate agent image and runtime, then run the signed standalone
integration probe:

```sh
make build
make agent-disk
make runtime

.build/runtime/container-runtime-netbsd probe \
    --disk "$PWD/.build/out/netbsd-vz-agent.raw" \
    --state "$PWD/.build/probe" \
    --timeout 120
```

The probe boots a CoW disk clone with persistent EFI state and verifies the
handshake, literal and configured execution, success/nonzero exits, concurrent
processes, exit/EOF ordering, PTY resize/input/signals, large binary stdio,
binary file copy, recursive directories, modes, symlinks, and traversal
rejection. The agent image locks password login, disables gettys and remote
services, and reserves `/dev/ttyVI10` for the root-owned protocol while
`/dev/ttyVI00` remains the boot log console.

The runtime builds against Apple Container 1.3.0 commit
`d6de5694200468d99a61662bfb9bb3aba763e3e5` and Containerization 0.41.0 plus the independently maintained
[`runtime-owned-resources` compatibility patch](compat/apple-container-runtime-owned-resources.patch).
The patch makes kernel, initfs, and rootfs optional for a runtime plugin that
declares this capability and forwards opaque `runtimeData`. An Apple Container
daemon built from that compatibility checkout is required for the integrated
CLI; the repository does not replace an installed daemon automatically.

Build the deterministic `netbsd/arm64` base image and platform kit, then install
the compatible daemon and two local plugins:

```sh
make platform-kit
make oci-base
make install-runtime

container image load --input .build/out/netbsd-oci-netbsd-11.0.tar
container netbsd create 11 --name demo -- /usr/bin/uname -a
container start demo

container netbsd run 11 --name one-shot --remove -- \
    /usr/bin/printf '%s\n' 'hello from NetBSD'
```

The assembler verifies layer digests and DiffIDs, rejects unsafe or unsupported
archive members, applies OCI whiteouts and metadata, injects only trusted
runtime assets, and caches immutable deterministic GPT/ESP/FFSv1 disks. The
public CLI accepts OCI images only; the standalone probe retains `--disk` for
development and regression testing.

See [docs/AGENT-RUNTIME.md](docs/AGENT-RUNTIME.md) for the architecture,
supported routes, transport behavior, and v1 limitations. The wire contract is
specified in [protocol/PROTOCOL.md](protocol/PROTOCOL.md).

## Console and security

EFI and early kernel output use the Virtio GPU's GOP display. Interactive
headless login becomes available through the stock getty on `/dev/ttyVI00`;
run `dmesg` after login to inspect the early kernel log.

The POC image retains the release set's empty root password. No inbound
service is enabled. Do not enable remote services or expose the image to an
untrusted network without setting a root password.

See [docs/TECHNICAL.md](docs/TECHNICAL.md) for the boot contract, disk format,
and remaining NetBSD patch set.

## License

MIT. See [LICENSE](LICENSE).
