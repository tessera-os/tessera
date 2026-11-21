# GuestController

Debug probe of one QEMU-emulated virtio-blk controller, driven by the
unmodified `VirtioGuest` discovery, negotiation, split-queue and block-request
code, from an EFI application after `ExitBootServices`.

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
   one 512-byte read of sector 0, then reset the device.
5. The guest hashes payload bytes 64..<512 and compares with the SHA-256 that
   the image header stores at bytes 32..<64.

`RunGuest.swift` runs two cases per ISA on a read-only, one-sector drive:
`positive` must print `TARWIN-GC-PASS`; `wrong-payload` (one payload bit
flipped after hashing) must print `TARWIN-GC-PAYLOAD-MISMATCH`. Both must
print the digest the host computed and shut down through `ResetSystem`.
QEMU's own `virtio_blk_*` trace must show exactly one read of that drive
(sector 0, one sector, `ret 0`) after the probe's DRIVER_OK, followed by
reset. The image must be unchanged afterwards.

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
  TRFS or to native queue enablement.
- The firmware's own virtio-blk driver reads the test drive before the probe
  starts; the runner reports that count and checks only the probe's read.
