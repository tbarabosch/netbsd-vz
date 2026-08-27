# NetBSD 11 through generic EFI on Apple Virtualization.framework

## 1. Boot contract

The POC has one boot path:

```text
VZEFIBootLoader
        |
        v
stock bootaa64.efi on a FAT32 ESP
        |
        v
stock GENERIC64 configuration and ACPI handoff
        |
        v
FFS root at NAME=netbsd-root
```

The stock `bootaa64.efi` is copied unchanged from the SHA-512-verified
NetBSD 11.0 base set. The kernel is built from the unmodified `GENERIC64`
configuration after applying exactly three generic Virtio driver patches.

There is no `VZLinuxBootLoader`, raw AArch64 Image, VZ64 kernel
configuration, direct-boot FDT patch, forced kernel console, initrd, boot
mode selector, or fallback to [the earlier direct-boot
implementation](https://tbarabosch.com/porting-netbsd-to-apple-vz/).

## 2. Why EFI is the better contract than our earlier direct-boot work

EFI enters NetBSD through the same firmware boundary used on normal arm64
systems. Firmware loads `bootaa64.efi` from standard removable-media paths,
the loader reads the kernel from the filesystem, and ACPI describes CPUs,
interrupts, timers, PCI, and Virtio devices to `GENERIC64`. This exercises
the stock loader-to-kernel interface instead of bypassing it.

[Our earlier direct-boot
work](https://tbarabosch.com/porting-netbsd-to-apple-vz/) used
`VZLinuxBootLoader` and placed more of the boot contract in this project. The
host had to supply a raw kernel Image and FDT, while NetBSD needed
corresponding AArch64 bootstrap, FDT console, Image-padding, and VZ64
configuration changes. Those changes were specific to this hosting
arrangement and therefore poor upstream candidates.

The generic EFI platform also gives the VM a stable machine identifier and
EFI variable store. Disk contents, firmware state, and ACPI device discovery
remain separate, conventional interfaces. That makes the guest image closer
to a normal bootable NetBSD disk and keeps platform policy out of the kernel.

EFI is not universally better. It adds an EFI System Partition, firmware
state, and a Virtio GPU for GOP, and firmware plus loader work can make boot
slower. The earlier approach remains attractive for firmware-free appliances
or very small boot chains. EFI is superior for this POC because its governing
goal is to minimize the NetBSD upstream delta: only generic Virtio fixes
remain.

## 3. VZ and NetBSD device contract

The runner configures the generic VZ platform, the minimum allowed CPU
count, 512 MiB RAM, EFI variable storage, a 1280 by 720 Virtio GPU, Virtio
serial, Virtio entropy, one writable Virtio block disk, and optional Virtio
NAT.

```text
VZ generic platform
  |
  +-- EFI + GOP ---------> bootaa64.efi
  |
  +-- ACPI --------------> CPU, GICv3, timer, PCI host bridge
  |
  +-- Virtio PCI --------> GPU, console, block, entropy
  |                         and optional network
  |
  +-- GPT disk ----------> ESP + NAME=netbsd-root
  |
  +-- ttyVI00 -----------> interactive headless login
```

EFI and the kernel choose GOP as the kernel console. The VZ Virtio serial
device is not an EFI console, so headless output begins when getty starts on
`/dev/ttyVI00`. The early kernel log remains available through `dmesg` after
login without changing NetBSD's console code.

## 4. Reproducible build

`scripts/build.sh` downloads the official NetBSD 11.0 `src`, `gnusrc`,
`sharesrc`, and `syssrc` sets and verifies pinned SHA-512 digests before
extraction. Patch content is part of the source-cache fingerprint.

NetBSD `build.sh` creates host-native AArch64 cross-tools, then runs:

```sh
build.sh -U -u -m evbarm -a aarch64 kernel=GENERIC64
```

The resulting ELF kernel is copied to:

```text
.build/out/netbsd-GENERIC64
```

No raw Image is published or padded.

## 5. Remaining NetBSD patches

The EFI build applies the files in `patches/` to pristine NetBSD 11.0 source
in this order:

```text
virtio-pci-memory.patch
virtio-reset.patch
vioif-mtu.patch
```

### PCI memory decoding

Modern Virtio capabilities are exposed through memory BARs.
`virtio_pci_attach` enabled bus mastering and I/O decoding but not
`PCI_COMMAND_MEM_ENABLE`; the patch enables memory decoding alongside the
existing bits.

### Reset completion

Virtio 1.0 requires a driver that writes device status zero to wait until a
later read returns zero. The patch polls the status byte after reset before
queue configuration continues.

### Network MTU

VZ NAT advertises `VIRTIO_NET_F_MTU`. The patch negotiates the feature and
applies the device's advertised MTU in `vioif`.

All three are generic driver corrections. None identifies Apple VZ or
alters EFI, ACPI, AArch64 bootstrap, FDT handling, or console selection.

## 6. EFI disk format

`scripts/build-disk.sh` downloads the official NetBSD 11.0
evbarm-aarch64 `base` and `etc` sets, verifies their pinned SHA-512 hashes,
applies a three-file root overlay, and builds a 1,088 MiB RAW disk.

```text
LBA 0                  protective MBR
LBA 1                  primary GPT header
LBA 2..33              primary GPT entries
LBA 34..2047           alignment gap
LBA 2048..133119       partition 1, 64 MiB FAT32 ESP
                       GPT label: netbsd-esp
                       /EFI/BOOT/BOOTAA64.EFI
                       /EFI/BOOT/boot.cfg
LBA 133120..2226175    partition 2, FFSv1
                       GPT label: netbsd-root
                       FFS label: netbsd-root
                       /netbsd is GENERIC64
final 2048 sectors     GPT reservation and backup GPT
```

`boot.cfg` requests:

```text
boot netbsd -v root=NAME=netbsd-root
```

The root overlay contains:

```text
/etc/fstab    named FFS root
/etc/rc.conf  services off; conditional vioif DHCP
/etc/ttys     ttyVI00 getty enabled, console getty disabled
```

## 7. Runner and state behavior

The Swift runner requires a disk and an EFI-state directory. It creates or
reloads a `VZGenericMachineIdentifier` and `VZEFIVariableStore`, configures
`VZEFIBootLoader`, connects the host terminal to Virtio serial, and runs the
VM until the guest stops or the configured timeout expires.

`scripts/run.sh` creates temporary EFI state by default. It also
copy-on-write clones the default disk before boot, so the published image is
not modified. A caller-supplied disk is attached directly, and a
caller-supplied EFI-state directory is reused.

Networking is deliberately opt-in. `make run-network` adds one Virtio
network device with `VZNATNetworkDeviceAttachment`; `make run` presents no
network device.

## 8. Limits

- Headless live output starts at the `ttyVI00` getty; EFI and early kernel
  output are on GOP.
- VZ NAT is opt-in. Bridging, inbound forwarding, directory sharing,
  suspend, secondary disks, and remote services are outside this POC.
- The image has an empty root password and is for isolated testing only.

## 9. Primary references

- [Earlier direct-boot NetBSD-on-VZ work](https://tbarabosch.com/porting-netbsd-to-apple-vz/)
- [NetBSD source build procedure](https://www.netbsd.org/docs/guide/en/chap-build.html)
- [NetBSD 11.0 source sets](https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/source/sets/)
- [NetBSD 11.0 evbarm-aarch64 sets](https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/evbarm-aarch64/binary/sets/)
- [Virtio 1.0 specification](https://docs.oasis-open.org/virtio/virtio/v1.0/virtio-v1.0.html)
- [Apple VZEFIBootLoader](https://developer.apple.com/documentation/virtualization/vzefibootloader)
- [Apple VZGenericPlatformConfiguration](https://developer.apple.com/documentation/virtualization/vzgenericplatformconfiguration)
- [Apple VZNATNetworkDeviceAttachment](https://developer.apple.com/documentation/virtualization/vznatnetworkdeviceattachment)
