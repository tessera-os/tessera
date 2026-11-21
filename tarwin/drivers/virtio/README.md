# virtio guest driver

Modern PCI and MMIO negotiation, split queue handling and baseline network and block drivers. DMA and configuration accessors come from DeviceKit. Hosted user-space library (regular Swift). Run `swift test` on macOS.

## QEMU block protocol check

From this package on macOS:

```sh
swift run -c release --package-path Tools/BlockQTest BlockQTest "$(command -v qemu-system-aarch64)"
```

The check creates its own 1 MiB scratch disk, finds a non-legacy virtio-blk MMIO transport on QEMU's Arm `virt` machine, negotiates VERSION_1 and ACCESS_PLATFORM and drives the Swift split queue against QEMU. It writes a sector, flushes, reads back, checks the used lengths, and verifies the on-disk sector and neighbouring bytes after QEMU exits. QTest controls synthetic RAM and MMIO: this is an independent device model test, **not** a booted Tarwin driver or an IOMMU/physical-device test.
