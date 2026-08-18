# NetBSD patches

These patches adapt the NetBSD 11.0 AArch64 kernel to the virtual hardware
provided by Apple Virtualization.framework.

```text
NetBSD 11.0 source
        |
        +-- viocon-console.patch
        +-- vz-platform.patch
        +-- vioif-mtu.patch
        `-- vz64-config.patch
                |
                v
             VZ64 kernel
```

The build applies them in that order.

## `viocon-console.patch`

What it does:

- makes Virtio console port 0 a NetBSD kernel console after `viocon(4)`
  attaches;
- implements the polling console operations used by the kernel and DDB;
- keeps using the driver's existing Virtio receive and transmit queues.

Why it matters:

VZ exposes the serial connection as a Virtio console. NetBSD 11 normally
attaches `viocon(4)` as a tty, but does not promote it to the kernel console.
Without this patch, the guest cannot provide the interactive console used by
the runner and smoke tests.

This is a late console. Output produced before PCI and `viocon(4)` attach is
not visible live; the smoke test replays it with `dmesg` after login.

Credit:

The implementation is substantially derived from `viocon(4)` kernel-console
support originally written by Taylor R. Campbell and carried in Emile "iMil"
Heitor's [ongoing full VirtIO console patch series for NetBSD](https://mail-index.netbsd.org/port-amd64/2026/01/22/msg003793.html).
This patch adapts the late-console portion for NetBSD 11 and VZ. It does not
include the series' early Virtio-MMIO console or multiport work.

## `vz-platform.patch`

What it does:

1. Makes the FDT bootstrap mapping compatible with an overlapping kernel
   mapping.
2. Enables PCI memory decoding so Virtio memory BARs are accessible.
3. Waits for a Virtio 1.0 device reset to finish before configuring queues.
4. Adds a no-match FDT console entry for kernels with no early console driver.

Why it matters:

The FDT describes the virtual machine to NetBSD. On VZ it can share a 2 MiB
mapping with the kernel, so incompatible mapping attributes stop early boot.
VZ's Virtio PCI devices use memory BARs and complete reset asynchronously;
without memory decoding and the reset wait, their queues never become usable.
The no-match console entry lets VZ64 intentionally rely on the late Virtio
console without leaving the FDT console linker set empty.

## `vioif-mtu.patch`

What it does:

- negotiates the Virtio network `VIRTIO_NET_F_MTU` feature;
- reads the advertised MTU from the device and applies it to `vioif(4)`.

Why it matters:

The VZ NAT device advertises the MTU feature. VZ rejected feature negotiation
when NetBSD ignored it, so `vioif(4)` could not attach. Accepting the feature
allows the guest to obtain a DHCP address and use the NAT network.

## `vz64-config.patch`

What it does:

- adds the project-specific `VZ64` kernel configuration;
- keeps the AArch64, FDT, PSCI, GICv3, timer, RTC, PCI, FFS, networking, and
  Virtio console/block/network/entropy paths used by VZ;
- keeps DDB, symbols, tracing, PTYs, IPv4/IPv6, and the filesystems needed by
  the root image;
- removes modules, memory disks, compatibility ABIs, ACPI/EFI, unrelated SoC
  and physical-device drivers, and unused protocol stacks.

Why it matters:

`GENERIC64` supports much more hardware than this VM exposes. VZ64 defines the
actual guest hardware contract, reduces the linked kernel, and makes missing
device support visible during the build. The published Image remains padded
to the fixed 8 MiB loader reservation required by VZ.

See [the technical account](../docs/TECHNICAL.md) for the boot failures that
led to these changes and the acceptance evidence for each device path.
