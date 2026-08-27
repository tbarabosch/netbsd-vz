# NetBSD 11 through generic EFI on Apple Virtualization.framework

## 1. Result

The supported boot contract is now:

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

This is materially closer to normal NetBSD hardware and virtualization than
the earlier direct-Image experiment. It removes all VZ-specific loader,
AArch64 bootstrap, FDT-console, raw-Image padding, forced-viocon-console, and
custom-kernel-configuration changes.

The remaining source delta is three generic Virtio fixes:

1. enable PCI memory decoding for modern Virtio PCI BARs;
2. wait until a Virtio 1.0 reset completes;
3. negotiate and apply the Virtio network MTU feature.

The stock bootaa64.efi binary is copied unchanged from the SHA-512-verified
NetBSD 11.0 base set. The kernel is built from the unmodified GENERIC64
configuration after applying only those three driver patches.

## 2. VZ and NetBSD device contract

The runner configures the generic VZ platform, minimum allowed CPU count,
512 MiB RAM, EFI variable storage, a 1280 by 720 Virtio GPU, Virtio serial,
Virtio entropy, one writable Virtio block disk, and optional Virtio NAT.

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
      +-- ttyVI00 -----------> headless login and smoke automation

Observed NetBSD attachments include acpifdt, acpi, gicvthree, armgtmr,
acpipchb, pci, viocon, ld, viogpu, viornd, and, when requested, vioif.

EFI and the kernel choose GOP as the kernel console. The VZ Virtio serial
device is not an EFI console, so headless output begins when getty starts on
/dev/ttyVI00. Smoke mode immediately runs dmesg after login to recover the
early kernel log without changing NetBSD's console code.

## 3. Reproducible native build

scripts/build.sh downloads the official NetBSD 11.0 src, gnusrc, sharesrc,
and syssrc sets and verifies pinned SHA-512 digests before extraction. Patch
content is part of the source-cache fingerprint.

NetBSD build.sh creates host-native AArch64 cross-tools, then runs:

    build.sh -U -u -m evbarm -a aarch64 kernel=GENERIC64

The resulting ELF kernel is copied to:

    .build/out/netbsd-GENERIC64

No AArch64 raw Image is published or padded. No VZ64 configuration exists.

## 4. Why the three patches remain

### PCI memory decoding

Apple's modern Virtio capabilities are exposed through memory BARs.
virtio_pci_attach previously enabled bus mastering and I/O decoding but not
PCI_COMMAND_MEM_ENABLE. The patch enables memory decoding alongside the
existing bits.

### Reset completion

Virtio 1.0 requires a driver that writes device status zero to wait until a
later read returns zero. VZ completes reset asynchronously. The patch polls
the status byte after reset before queue configuration continues.

### Network MTU

VZ NAT advertises VIRTIO_NET_F_MTU. The NetBSD 11 vioif driver did not accept
that bit, so VZ rejected FEATURES_OK and the network device did not attach.
The patch negotiates the feature and applies the advertised MTU.

All three changes are generic driver corrections; none identifies Apple VZ
or alters EFI, ACPI, AArch64 bootstrap, or console code.

## 5. Pristine-source patch matrix

The EFI path was first evaluated from an isolated pristine NetBSD 11.0 tree.
The earlier direct-boot patches were explicitly absent.

    Patch set                         Offline result       NAT result
    -------------------------------- -------------------- --------------------
    none                              no ttyVI00 login     not tested
    PCI memory only                   no ttyVI00 login     not tested
    PCI memory + reset wait           passed              failed to reach login
    PCI memory + reset + MTU           passed              passed

The progression establishes the two Virtio PCI changes as the working
storage/console boundary and the MTU change as the additional network
requirement. There was no reason to introduce any loader, ACPI, FDT,
bootstrap, console, or VZ-specific kernel patch.

## 6. EFI disk format

scripts/build-disk.sh downloads the official NetBSD 11.0 evbarm-aarch64 base
and etc sets, verifies their pinned SHA-512 hashes, applies the three-file
root overlay, and builds a deterministic 1,088 MiB RAW disk.

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

boot.cfg requests:

    boot netbsd -v root=NAME=netbsd-root

The root overlay contains:

    /etc/fstab    named FFS root
    /etc/rc.conf  services off; conditional vioif DHCP
    /etc/ttys     ttyVI00 getty enabled, console getty disabled

The proof image keeps the release set's empty root password for serial
automation. It must not be treated as a production image.

## 7. Runner and state behavior

The Swift runner has one boot path. It requires a disk and an EFI-state
directory, creates or reloads a VZGenericMachineIdentifier and
VZEFIVariableStore there, configures VZEFIBootLoader, and starts the VM.
There is no boot selector, kernel path, command-line override, initrd, or
VZLinuxBootLoader.

scripts/run.sh creates disposable EFI state by default. It also copy-on-write
clones the default disk before boot, so normal interactive and smoke runs do
not mutate the published image. Passing another DISK attaches that file
directly for intentional persistence.

Smoke mode implements a bounded serial state machine:

    wait for login
      -> log in as root
      -> replay dmesg
      -> require EFI/ACPI and Virtio attachment evidence
      -> require userspace marker
      -> optional DHCP, route, gateway ping, and 8.8.8.8 ping
      -> request shutdown -p
      -> observe shutdown hooks and VZ stopped state

The stock kernel sends the final VFS unmount line to GOP rather than
ttyVI00. The automated clean-shutdown evidence is therefore the completed
shutdown-hook marker followed by VZ's stopped state. The persistence test
then reboots the same disk, recovers a synced marker, and shuts it down
again, proving the prior disk remains consistently reusable without a
console patch.

## 8. Acceptance evidence

The NetBSD 11.0 gate completed:

- five consecutive cold boots, each with a new machine identifier and EFI
  variable store;
- offline smoke with no vioif attachment;
- NAT smoke with vioif, carrier, DHCP IPv4, default route, gateway ping, and
  public ping;
- automated login and command execution on ttyVI00;
- ACPI, GICv3, generic timer, PCI, console, GPU, storage, entropy, and named
  root attachment;
- root mounted from NAME=netbsd-root;
- two-boot disk and EFI-state persistence with a recovered marker;
- shutdown hooks completed and VZ reached the stopped state on every accepted
  smoke boot.

Recorded non-blocking measurements from the accepted host:

    Artifact or run                    Measurement
    ---------------------------------  ----------------
    NetBSD 11.0 GENERIC64 ELF          18,267,080 bytes
    EFI RAW disk                       1,140,850,688 bytes
    direct-boot baseline smoke         about 15 seconds
    EFI offline smoke                  about 25 seconds
    EFI NAT smoke                      about 33 seconds

These are end-to-end runner times, not firmware-only benchmarks.

## 9. NetBSD-current upstream check

The same three patch files applied without edits to the official
NetBSD-current source snapshot published 22 August 2026. That snapshot
identified itself as NetBSD 11.99.7. Its relevant published component
SHA-512 values were:

    top-level  08cd1b8800f55f51363e5dd5e8e5896eb55657acce5b4d1fe17df094e1e3f82c6a6d8761bed1c9d23c586c147838748bed32737306ed08e725020c3955fb9f06
    share      3d3736bca5603d9b6e0f87c54cd9a31758b307001f40f4b6858fbaba4ea03fa2c964120c0bc20ad435fb2657ff7cc5a4693e004cc43e84949ba4f9e2443350c5
    sys        936010d3927e1436cb41a542d65b9746949866116bf3a10565f60c7f48fb8775c734bbab9cca68f7f6a2e4526253bc46ba4fac74bd66219cae1a5d2dd76c2952

Stock current GENERIC64 built successfully as a 19,926,424-byte ELF. A disk
containing that kernel and the unchanged stock NetBSD 11.0 bootaa64.efi and
userland passed both offline and NAT smoke tests on VZ. This validates the
patches against current source and runtime behavior, rather than only
checking whether patch hunks apply.

## 10. Limits

- Headless live output starts at ttyVI00 getty; EFI and early kernel output
  are on GOP.
- VZ NAT is opt-in. Bridging, inbound forwarding, DNS validation, suspend,
  directory sharing, and secondary disks are outside this proof.
- Network smoke depends on outbound ICMP to 8.8.8.8.
- The image has an empty root password and is for isolated testing only.

## 11. Primary references

- [NetBSD source build procedure](https://www.netbsd.org/docs/guide/en/chap-build.html)
- [NetBSD 11.0 source sets](https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/source/sets/)
- [NetBSD 11.0 evbarm-aarch64 sets](https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/evbarm-aarch64/binary/sets/)
- [NetBSD-current source snapshots](https://cdn.netbsd.org/pub/NetBSD/NetBSD-current/tar_files/)
- [Virtio 1.0 specification](https://docs.oasis-open.org/virtio/virtio/v1.0/virtio-v1.0.html)
- [Apple VZEFIBootLoader](https://developer.apple.com/documentation/virtualization/vzefibootloader)
- [Apple VZGenericPlatformConfiguration](https://developer.apple.com/documentation/virtualization/vzgenericplatformconfiguration)
- [Apple VZNATNetworkDeviceAttachment](https://developer.apple.com/documentation/virtualization/vznatnetworkdeviceattachment)
