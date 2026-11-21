# GuestController

Debug probe of one QEMU-emulated virtio-blk controller, driven by the
unmodified `VirtioGuest` discovery, negotiation, split-queue and block-request
code, from an EFI application after `ExitBootServices`. The same read path
also backs the unmodified `trfs/tests/GuestIO` reader, which mounts the
repository's 1 MiB TRFS system fixture.

```sh
EMBEDDED_SWIFTC=<swift.org 6.3 toolchain>/usr/bin/swiftc \
QEMU_FIRMWARE=<dir with edk2-*-code.fd and edk2-*-vars.fd> \
EDK_BASETOOLS=<edk2-stable202408>/BaseTools \
bash run.sh [aarch64] [x86_64] [riscv64]
```

Requires QEMU with the `log` trace backend, a host `swiftc` (Foundation and
CryptoKit, so macOS) for `RunGuest.swift` and `Access.swift`, and, for RV64
only, EDK II `GenFw` built in `BaseTools/Source/C`. Set
`GUEST_CONTROLLER_OUT` to keep the build, console, QMP and trace logs.

## What one run does

1. Before exit: finds the single modern virtio-blk (`1af4:1042`) behind a PCIe
   root port with read-only config reads through the firmware root-bridge
   protocol, reserves loader pages and reads the MCFG. No device I/O.
2. `FirmwareBootServices.finish` exits boot services. Output then goes to the
   raw UART (COM1, PL011 or 16550); only `ResetSystem` is called afterwards.
3. Walks ECAM from the MCFG, requires the same function, sizes its BARs and
   enables memory decode and bus mastering for it alone.
4. `discoverVirtioPci`, `negotiatePci` (offering SIZE_MAX, SEG_MAX and RO;
   VERSION_1 and ACCESS_PLATFORM stay mandatory), `BlockConfiguration.snapshot`,
   `setupPciQueue`, `SplitQueue`, `submitBlock` and `blockCompletion` perform
   the reads, then reset the device. A one-sector drive gets one 512-byte
   read of sector 0; a 2048-sector drive gets the TRFS reads below.
5. One-sector drive: the guest hashes payload bytes 64..<512 and compares with
   the SHA-256 that the image header stores at bytes 32..<64.
6. TRFS drive: the probe hands `exerciseGuestStorage` from
   `trfs/tests/GuestIO/Storage.swift` (compiled in unchanged) a 16 KiB loader
   page workspace and a `GuestStorageTransport`. Each exchange must carry a
   `TarwinBlockWire` read of 8 aligned sectors with the one 4 KiB vector that
   reader sends; the probe reads those sectors straight into the grant's
   payload page with one virtio request and posts one `.ok` completion. The
   reader mounts against its pinned root and checks `system-version` page 0.
   A malformed request or a controller fault prints `TARWIN-GC-FAIL`, kept
   apart from TRFS rejecting what it read.

`RunGuest.swift` runs two cases per ISA on a read-only, one-sector drive:
`positive` must print `TARWIN-GC-PASS`; `wrong-payload` (one payload bit
flipped after hashing) must print `TARWIN-GC-PAYLOAD-MISMATCH`. Both must
print the digest the host computed and shut down through `ResetSystem`.
QEMU's own `virtio_blk_*` trace must show exactly one read of that drive
(sector 0, one sector, `ret 0`) after the probe's DRIVER_OK, followed by
reset. The image must be unchanged afterwards.

It then runs three cases on a read-only drive holding the fixture written by
the unmodified `trfs/tests/fixtures/make-system-image.swift` (its root file
must hash page 6). Damage flips one byte as the GuestIO host check does:

| case | drive | guest must print | reads after DRIVER_OK |
|---|---|---|---|
| `trfs-clean` | fixture | `TARWIN-GC-TRFS-PASS` | 11 |
| `trfs-damaged-file` | page 4 (`system-version` data) damaged | `TARWIN-GC-TRFS-REJECTED` | 11 |
| `trfs-damaged-root` | page 6 (pinned root record) damaged | `TARWIN-GC-TRFS-REJECTED` | 3 |

The read counts match the GuestIO host check on the same fixture. Every
traced read must be 8 aligned sectors inside the drive with `ret 0`, the
guest's request count must match QEMU's, and the image must be unchanged.

## Limits

- An EFI application, not a Tarwin kernel, DeviceKit service or signed
  launch. No native kernel entry is shown.
- Queue and buffers are identity-mapped loader pages with no vIOMMU, so the
  run shows no DMA isolation; `iommu_platform=on` only lets the device offer
  ACCESS_PLATFORM, which the driver requires and the probe does not relax.
- QEMU device model only, under TCG: the runner refuses any device other
  than `virtio-blk-pci` and `pcie-root-port`, and any VFIO, HVF or KVM
  option. No physical device, write, flush or discard path.
- Unsigned. Not a W1 image or an admitted native profile, and not wired to
  native queue enablement. TRFS runs only as the GuestIO test reader inside
  this EFI probe, not as a TRFS service or mount in a Tarwin kernel.
- The firmware's own virtio-blk driver reads the test drive before the probe
  starts; the runner reports that count and checks only the probe's read.
