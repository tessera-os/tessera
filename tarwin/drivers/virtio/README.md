# virtio guest driver

Modern PCI and MMIO negotiation, split queue handling and baseline network and block drivers. DMA and configuration accessors come from DeviceKit. Hosted user-space library (regular Swift). Run `swift test` on macOS.

## QEMU block and network protocol checks

From this package on macOS:

```sh
for isa in aarch64 x86_64 riscv64; do
  swift run -c release --package-path Tools/BlockQTest BlockQTest "$(command -v qemu-system-$isa)" || exit 1
done
```

The check creates its own 1 MiB scratch disk, discovers modern virtio-blk over MMIO on Arm/RISC-V `virt` and over PCI on x86-64 `q35`, negotiates VERSION_1 and ACCESS_PLATFORM and drives the Swift split queue against QEMU. The Mac-hosted block scheduler publishes each request on an A.4 ring. The Swift guest service validates the vector grant, drives the virtio device, and returns a completion through a second ring to the scheduler. It writes a sector, flushes, reads back, checks the used lengths, and verifies the on-disk sector and neighbouring bytes after QEMU exits. Two modern virtio-net NICs on a private in-process QEMU hub exchange a frame; the check verifies both used-ring completions, the entire Ethernet frame and the adjacent receive-buffer byte. The hub has no host uplink. The test process and Swift driver code execute on the Mac. QTest controls synthetic RAM and device registers: this is an independent device model test, **not** a booted Tarwin driver or an IOMMU/physical-device test.

The hosted block QTest also checks each operation's terminal LibTessera I/O packet (kind, key, status and byte count), its waiter notification and the release of its port reference. It does not emulate CPU interrupt entry or IOMMU invalidation.
