# virtio guest driver

Modern PCI and MMIO negotiation, split queue handling and baseline network and block drivers. DMA and configuration accessors come from DeviceKit. Hosted user-space library (regular Swift). Run `swift test` on macOS.

## QEMU block protocol check

From this package on macOS:

```sh
for isa in aarch64 x86_64 riscv64; do
  swift run -c release --package-path Tools/BlockQTest BlockQTest "$(command -v qemu-system-$isa)" || exit 1
done
```

The check creates its own 1 MiB scratch disk, discovers modern virtio-blk over MMIO on Arm/RISC-V `virt` and over PCI on x86-64 `q35`, negotiates VERSION_1 and ACCESS_PLATFORM and drives the Swift split queue against QEMU. It writes a sector, flushes, reads back, checks the used lengths, and verifies the on-disk sector and neighbouring bytes after QEMU exits. The test process and Swift driver code execute on the Mac. QTest controls synthetic RAM and device registers: this is an independent device model test, **not** a booted Tarwin driver or an IOMMU/physical-device test.
