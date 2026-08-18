# NetBSD 11 on Apple Virtualization.framework

## 1. Result and supported boundary

This repository boots NetBSD 11.0/evbarm-aarch64 directly with Apple's
Virtualization.framework. The supported guest consists of:

- the project-specific `VZ64` kernel;
- one Virtio console and one Virtio entropy device;
- an optional Virtio block device containing a GPT/FFSv1 root filesystem;
- an optional Virtio network device attached to VZ NAT.

The disk-backed smoke test reaches `getty`, logs in as root, runs a shell
command, shuts down inside NetBSD, cleanly unmounts FFS, and reaches the VZ
stopped state. The network variant also verifies DHCP, the default gateway,
and IPv4 reachability to `8.8.8.8`.

`VZLinuxBootLoader` is the API name of Apple's direct AArch64 Image loader.
The guest is NetBSD and no Linux component runs in the VM.

## 2. Host and guest architecture

```text
NetBSD 11.0 source sets                 NetBSD 11.0 binary sets
            |                                base + etc
            v                                    |
       four patches                              v
            |                            mtree + MAKEDEV + overlay
            v                                    |
    build.sh kernel=VZ64                         v
            |                           little-endian FFSv1
            v                                    |
  netbsd-VZ64-vz.img                             v
            |                            protective MBR + GPT
            +----------------+-------------------+
                             |
                             v
                 Virtualization.framework
                 +-----------------------+
                 | direct Image loader   |
host stdin/out <-| Virtio console        |
 RAW file <----->| Virtio block          |
 optional NAT <--| Virtio network        |
                 | Virtio entropy        |
                 +-----------+-----------+
                             |
                             v
                 NetBSD VZ64 -> FFS root -> init
```

The root-tree staging directory is independent of the GPT wrapper. It can be
reused later without treating the VZ-specific RAW disk as the root-tree
format.

## 3. Native source and cross-build path

`scripts/build.sh` downloads the official NetBSD 11.0 `src`, `gnusrc`,
`sharesrc`, and `syssrc` archives and checks their pinned SHA-512 hashes. It
extracts them under `.build/source`, applies the four tracked patches, and
uses NetBSD's `build.sh` to produce Darwin-hosted AArch64 cross tools:

```text
macOS arm64
    |
    +-- NetBSD build.sh ... tools
    |       `-- .build/tools/bin/aarch64--netbsd-*
    |
    `-- NetBSD build.sh ... kernel=VZ64
            `-- netbsd.img
```

Source archive hashes and patch hashes form the patched-source cache key. The
host version, Xcode version, compiler version, source hashes, and repository
path form the cross-tool cache key. A mismatch discards only the affected
generated cache.

The linked VZ64 payload measured 5,727,568 bytes in the accepted build. The
published Image is padded and its AArch64 header regenerated for an exact
8,388,608-byte loader reservation. Without that reservation, VZ placed
adjacent boot data close enough to the reduced image to prevent startup. The
builder rejects a linked payload that reaches the reservation and verifies
the final size, declared size, and `ARM\x64` header magic.

The historical GENERIC64 investigation image was 16,901,860 bytes. GENERIC64
is not a build target in this repository.

## 4. Required kernel patches

### 4.1 Late Virtio console

`patches/viocon-console.patch` is substantially derived from the
`viocon(4)` kernel-console support originally written by Taylor R. Campbell.
That work is carried as patch 2 in Emile "iMil" Heitor's
[ongoing full VirtIO console patch series for NetBSD](https://mail-index.netbsd.org/port-amd64/2026/01/22/msg003793.html).
This repository adapts its late-console portion to NetBSD 11 and VZ; the
console-selection condition and diagnostic banner are VZ-specific. It does
not include the series' Virtio-MMIO early console or multiport work.

The patch turns port zero into a NetBSD kernel console when no normal console
has already attached. It provides polling `cngetc`, `cnputc`, and `cnpollc`
operations using the driver's existing receive and transmit virtqueues.

The console attaches only after FDT, PCI, Virtio PCI, and `viocon` discovery:

```text
kernel entry -> initarm -> autoconfiguration -> PCI -> virtio -> viocon
     no visible output                                      |
                                                            v
                                              kernel console becomes live
```

This is intentionally not an early-console implementation. Messages emitted
before `viocon` attaches are recovered by running `dmesg` after login.

### 4.2 VZ platform fixes

`patches/vz-platform.patch` contains four VZ bootstrap and Virtio fixes.

FDT mapping: VZ passes the FDT in `x0`. The observed FDT mapping can share a
2 MiB L2 block with NetBSD's kernel bootstrap mapping. The original FDT
mapping requested UXN and PXN while the existing block used UXN. Keeping the
FDT mapping at UXN makes the attributes compatible so `pmapboot_enter` can
reuse the block.

PCI decoding: Apple's modern Virtio capabilities are in memory BARs. The PCI
attach path must set `PCI_COMMAND_MEM_ENABLE` in addition to bus mastering and
I/O decoding.

Virtio reset: Virtio 1.0 requires a driver that writes device status zero to
wait until a later read returns zero. VZ completes reset asynchronously.
Without the wait, queue setup did not persist and the console queue remained
inactive. The patch polls the status byte after reset before continuing.

No-console sentinel: VZ64 has no early FDT console driver. NetBSD's FDT
console linker set must still exist, so the patch registers a zero-priority
sentinel that never matches. A real FDT console would supersede it.

### 4.3 Virtio network MTU

`patches/vioif-mtu.patch` negotiates `VIRTIO_NET_F_MTU` and applies the MTU
reported in the device configuration. VZ NAT advertises this feature and
rejected `FEATURES_OK` when the NetBSD driver did not accept it.

### 4.4 VZ64 configuration

`patches/vz64-config.patch` adds the only supported kernel configuration,
`sys/arch/evbarm/conf/VZ64`. It keeps the diagnosed VZ device path, a balanced
appliance userspace, and debugging support. It removes broad evbarm hardware,
legacy ABIs, modules, memory disks, ACPI/EFI, and unused protocol and device
families.

## 5. VZ hardware and kernel contract

```text
VZ facility                         NetBSD VZ64 support
----------------------------------  ---------------------------------
AArch64 CPU                         Cortex, SMP-ready native ABI
Flattened device tree               armfdt, simplebus
CPU power/control                   PSCI
Interrupt controller               GICv3
Clock                               generic timer, fixed clock
RTC and power key                   PL031 RTC, PL061 GPIO path
PCI                                 generic FDT PCI host
Console                             virtio-pci -> viocon
Root storage                        virtio-pci -> ld -> GPT wedge
Network                             virtio-pci -> vioif
Entropy                             virtio-pci -> viornd
```

VZ64 retains FFS, WAPBL, named GPT wedges, FDESC, KERNFS, PROCFS, PTYFS,
TMPFS, NULLFS, IPv4, IPv6, loopback, BPF, SysV IPC, PTYs, tracing, PaX,
`drvctl`, `clockctl`, kernel symbols, embedded configuration, and DDB.

It omits modules and autoloading, memory disks, NetBSD32 and historical ABI
compatibility, EFI/ACPI, physical storage and network drivers, display,
audio, USB, SCSI, NFS, IPsec, PPP, tunnels, RAID, and unused Virtio drivers.
The shipped kernel cannot consume an initrd; the runner retains `--initrd` for
external kernels.

The runner configures one minimum-sized virtual CPU, 512 MiB RAM, a generic VZ
platform, a Virtio serial console, and Virtio entropy. Disk and NAT devices
are added only when requested. Device unit numbers are discovered by NetBSD
and are not stable identifiers.

## 6. Root tree, FFS, and GPT

`scripts/build-disk.sh` downloads the official NetBSD 11.0
`evbarm-aarch64` `base.tar.xz` and `etc.tar.xz` sets and verifies their pinned
SHA-512 hashes. It extracts both sets while preserving modes and symlinks.

The release mtree manifests are concatenated after removing stale `size=`
attributes. `MAKEDEV -s all ipty` appends device metadata for the console,
Virtio console, `ld`, `dk`, and PTY nodes. The builder refuses to continue
without `/sbin/init`, `/bin/sh`, `/usr/libexec/getty`, `/etc/rc`, and the
required device entries.

The tracked overlay contains only:

```text
/etc/fstab    NAME=netbsd-root / ffs rw 1 1
/etc/rc.conf  hostname, no swap, services off, conditional vioif DHCP
/etc/ttys     secure console getty on, constty off
```

`rc.conf` starts `dhcpcd -qM --waitip=4 --timeout 30` only when a `vioif*`
interface exists. `auto_ifconfig`, SSH, inetd, and postfix remain disabled.

`nbmakefs` builds a little-endian FFSv1 image with 16 KiB blocks, 2 KiB
fragments, density 8192, and filesystem label `netbsd-root`. `nbgpt` creates
the protective MBR and both GPT copies around it.

```text
1 GiB RAW disk: 2,097,152 sectors of 512 bytes

LBA 0                 protective MBR
LBA 1                 primary GPT header
LBA 2..33             primary GPT entries
LBA 34..2047          alignment gap
LBA 2048..2095103     partition 1, 2,093,056 sectors
                      type: NetBSD FFS
                      GPT label: netbsd-root
                      contents: FFSv1 label netbsd-root
LBA 2095104..2097118  reserved gap
LBA 2097119..2097150  backup GPT entries
LBA 2097151           backup GPT header
```

There is no EFI partition, swap partition, nested BSD disklabel, kernel set,
modules set, or network-specific disk variant.

## 7. Runner flows

Interactive disk boot uses direct host stdin and streams the console until the
timeout:

```text
pristine RAW --cp -c--> disposable RAW --read/write--> Virtio block
host stdin -------------------------------------------> Virtio console RX
host stdout <------------------------------------------ Virtio console TX
                                         timeout -> host stop -> clone removed
```

A caller-supplied `DISK` bypasses cloning and is attached directly for
intentional persistence. Kernel-only mode omits the disk and reaches NetBSD's
`root device:` prompt. `--command-line` replaces the default command line
exactly; `--initrd` and alternate image paths remain available for external
kernels.

Smoke mode replaces direct stdin with a host pipe and runs a bounded state
machine:

```text
wait "login:" -> send root -> wait "# " -> send dmesg
      |
      v
send userspace marker -> require NETBSD_VZ_USERSPACE_OK
      |
      +-- offline: reject vioif ------------------------+
      |                                                 |
      `-- network: interface/carrier/address/route       |
                    -> ping gateway                      |
                    -> ping 8.8.8.8                      |
                    -> require NETBSD_VZ_NETWORK_OK      |
                                                        v
                                           shutdown -p now
                                                        |
                                                        v
                                  clean FFS unmount + VZ stopped
```

Fatal root-mount, init, and panic messages abort smoke mode. A timeout or
failure requests a host-side stop and preserves the console transcript.
Successful transcripts and all default writable clones are removed.

## 8. Acceptance evidence

Offline smoke requires the login and shell marker, no `vioif` attachment,
clean root unmount, and guest poweroff. The replayed `dmesg` provides the
hardware and root path:

```text
cpu0 at ...
psci0 at ...
gicvthree0 at ...
gtmr0 at ...
plrtc0 at ...
pcihost0 at ...
viocon0 at virtio...
ld0 at virtio...
viornd0 at virtio...
dk0 at ld0: "netbsd-root" ... type: ffs
root on dk0
root file system type: ffs
login: root
NETBSD_VZ_USERSPACE_OK
unmounted /dev/dk0 on / type ffs
```

Unit numbers can differ. Root selection uses the stable GPT wedge name from
`-v root=NAME=netbsd-root`.

Network smoke additionally requires:

```text
vioifN at virtioN
status: active
inet A.B.C.D                    not 169.254/16
default gateway G.G.G.G
one successful ping to G.G.G.G
one successful ping to 8.8.8.8
NETBSD_VZ_NETWORK_OK
```

`make run-kernel` retains the diskless regression and is expected to print
`root device:` before its default timeout.

## 9. Limitations and security boundary

- The console is late; failures before Virtio PCI attachment are silent.
- VZ NAT is opt-in. Bridging, port forwarding, DNS validation, and inbound
  services are not implemented.
- The network smoke test depends on outbound ICMP to `8.8.8.8` being allowed.
- The release set's empty root password is retained only for console testing.
  Set a password before enabling any remote service.
- The default disk clone is disposable. A caller-supplied disk is persistent.
- No graphics, directory sharing, secondary volumes, suspend/resume, or EFI
  boot path is supported.
- Apple Container assumes a Linux-oriented guest/runtime contract. OCI and
  Apple Container integration are outside this repository's current scope.

## 10. Primary references

- [NetBSD source build procedure](https://www.netbsd.org/docs/guide/en/chap-build.html)
- [NetBSD 11.0 source sets](https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/source/sets/)
- [NetBSD 11.0 evbarm-aarch64 sets](https://cdn.netbsd.org/pub/NetBSD/NetBSD-11.0/evbarm-aarch64/binary/sets/)
- [NetBSD viocon(4)](https://man.netbsd.org/viocon.4)
- [NetBSD full VirtIO console patchset review](https://mail-index.netbsd.org/port-amd64/2026/01/22/msg003793.html)
- [NetBSD vioif(4)](https://man.netbsd.org/vioif.4)
- [Virtio 1.0 specification](https://docs.oasis-open.org/virtio/virtio/v1.0/virtio-v1.0.html)
- [Apple VZLinuxBootLoader](https://developer.apple.com/documentation/virtualization/vzlinuxbootloader)
- [Apple VZVirtioBlockDeviceConfiguration](https://developer.apple.com/documentation/virtualization/vzvirtioblockdeviceconfiguration)
- [Apple VZNATNetworkDeviceAttachment](https://developer.apple.com/documentation/virtualization/vznatnetworkdeviceattachment)
