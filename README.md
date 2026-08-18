# NetBSD 11 on Apple Virtualization.framework

Build and boot a reduced NetBSD 11.0 AArch64 kernel and an FFS root disk on
Apple Silicon macOS. The VM uses Virtualization.framework directly; Apple
Container is not involved.

## Requirements

- Apple Silicon Mac with Virtualization.framework
- Xcode or Xcode Command Line Tools selected with `xcode-select`
- `make` and network access to the official NetBSD archives
- about 10 GiB of free space for source, tools, objects, and images

The first kernel build downloads verified NetBSD 11.0 source sets and builds
the NetBSD AArch64 cross tools locally.

## Build and run

```sh
make build
make disk

make run                 # interactive, networkless disk boot
make run-network         # interactive disk boot with VZ NAT
make run-kernel          # diskless root-device prompt
make smoke               # networkless userspace proof
make smoke-network       # DHCP and Internet IPv4 proof
make clean
```

`make run` and both smoke targets use a disposable writable clone of the
default disk. `make clean` removes objects and outputs but retains downloads,
the patched source tree, and cross tools.

## Outputs

```text
.build/out/netbsd-VZ64-vz.img
.build/out/netbsd-vz-root.raw
```

The kernel image is exactly 8 MiB. The disk is a 1 GiB RAW image containing
one GPT partition with a little-endian FFSv1 root filesystem.

## Overrides

```sh
NETBSD_VZ_JOBS=8 make build
NETBSD_VZ_TIMEOUT=120 make run
IMAGE=/absolute/path/netbsd.img make run-kernel
IMAGE=/absolute/path/netbsd.img DISK=/absolute/path/root.raw make run
```

`IMAGE` selects another AArch64 Image. A caller-supplied `DISK` is attached
directly and is therefore persistent. The Swift runner also supports
`--initrd` and an exact `--command-line` override for external kernels.

Disk runs default to 90 seconds. Diskless runs default to 10 seconds.

## Security

The release set's empty root password is retained for the isolated console
proof. No inbound service is enabled. Networking is attached only by
`run-network` and `smoke-network`; do not use this image on an untrusted
network or enable remote services without setting a root password first.

See [docs/TECHNICAL.md](docs/TECHNICAL.md) for the kernel changes, disk format,
VZ hardware contract, and acceptance tests.
