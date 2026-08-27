# Minimal NetBSD patch set

The EFI build applies exactly three generic Virtio fixes to pristine NetBSD
11.0 source, in this order:

    virtio-pci-memory.patch
    virtio-reset.patch
    vioif-mtu.patch

## virtio-pci-memory.patch

Enables PCI_COMMAND_MEM_ENABLE when virtio_pci attaches, alongside the
existing bus-master and I/O-enable bits. Modern Virtio PCI capabilities live
in memory BARs, so those BARs cannot be used while memory decoding is off.

## virtio-reset.patch

After writing device status zero, polls until a Virtio 1.0 device reports
zero. The Virtio specification requires this reset-completion wait, and VZ
completes reset asynchronously.

## vioif-mtu.patch

Negotiates VIRTIO_NET_F_MTU and applies the device's advertised MTU to
vioif. VZ NAT advertises this feature and rejects FEATURES_OK if the driver
does not accept it.

## Deliberately absent

There are no patches for bootaa64.efi, EFI, ACPI, AArch64 bootstrap, FDT,
kernel-console selection, or an Apple-specific platform. There is no VZ64
kernel configuration. The build uses stock GENERIC64 and the serial login is
provided by a normal getty on ttyVI00.

See [the technical account](../docs/TECHNICAL.md) for the EFI boot contract
and disk layout.
