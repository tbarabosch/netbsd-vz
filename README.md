# NetBSD 11 EFI boot on Apple Virtualization.framework

Build and boot NetBSD 11.0/evbarm-aarch64 on Apple Silicon macOS through
Virtualization.framework's generic EFI platform. The guest uses the stock
NetBSD bootaa64.efi loader and stock GENERIC64 kernel configuration.

Only three generic NetBSD Virtio fixes are applied: PCI memory decoding,
reset-completion waiting, and network MTU negotiation. There is no
VZ-specific kernel configuration, loader change, FDT bootstrap change, forced
kernel console, raw AArch64 Image, or direct-boot fallback.

## Requirements

- Apple Silicon Mac with Virtualization.framework
- Xcode or Xcode Command Line Tools selected with xcode-select
- make and network access to the official NetBSD archives
- about 10 GiB of free space for source, tools, objects, and images

The first build downloads SHA-512-pinned NetBSD 11.0 source sets and builds
the NetBSD AArch64 cross-tools locally.

## Build and run

    make build
    make disk

    make run                 # interactive, networkless EFI boot
    make run-network         # interactive EFI boot with VZ NAT
    make smoke               # offline EFI/ACPI and userspace proof
    make smoke-network       # DHCP, gateway, and public IPv4 proof
    make smoke-persistence   # reuse one disk and EFI variable store
    make smoke-repeat        # five consecutive fresh-state cold boots
    make clean

The normal run and smoke targets boot a disposable writable clone of the
default disk and use disposable EFI variable state. A caller-supplied DISK is
attached directly, so changes to it persist.

## Output and overrides

    .build/out/netbsd-GENERIC64
    .build/out/netbsd-vz.raw

netbsd-vz.raw is a 1,088 MiB GPT disk. It contains a 64 MiB FAT32 EFI System
Partition followed by an FFSv1 root partition named netbsd-root.

    NETBSD_VZ_JOBS=8 make build
    NETBSD_VZ_TIMEOUT=180 make run
    DISK=/absolute/path/netbsd.raw make run
    ./scripts/run.sh --disk /absolute/path/netbsd.raw \
        --efi-state /absolute/path/persistent-efi-state

The runner always uses EFI. There is deliberately no boot-mode selector.
Networking is opt-in.

## Console and security

EFI and the kernel use the Virtio GPU's GOP display. Headless automation logs
in through a stock getty on /dev/ttyVI00; early boot messages are replayed
with dmesg after login.

The proof image retains the release set's empty root password for isolated
console automation. No inbound service is enabled. Do not enable remote
services or expose the image to an untrusted network without setting a root
password.

See [docs/TECHNICAL.md](docs/TECHNICAL.md) for the boot contract, patch
evidence, disk format, NetBSD-current test, and acceptance results.

## License

MIT. See [LICENSE](LICENSE).
