# virtio guest driver

Modern PCI and MMIO negotiation, split queue handling and baseline network and block drivers. DMA and configuration accessors come from DeviceKit. Hosted user-space library (regular Swift). Run `swift test` on macOS.

## QEMU block and network protocol checks

From this package on macOS:

```sh
for isa in aarch64 x86_64 riscv64; do
  swift run -c release --package-path Tools/BlockQTest BlockQTest "$(command -v qemu-system-$isa)" || exit 1
done
```

The check creates its own 1 MiB scratch disk, discovers modern virtio-blk over MMIO on Arm/RISC-V `virt` and over PCI on x86-64 `q35`, negotiates VERSION_1 and ACCESS_PLATFORM and drives the Swift split queue against QEMU. The Mac-hosted block scheduler publishes each request on an A.4 ring. The Swift guest service validates the vector grant, drives the virtio device, and returns a completion through a second ring to the scheduler. It writes a sector, flushes and reads it back, then zeroes three previously nonzero sectors, discards eight aligned sectors, and flushes again. The driver reads the capacity and feature-dependent range limits from one generation-consistent config snapshot; both range commands use a private 16-byte record and complete on the client port. The test checks every backing byte after QEMU exits, except for the discarded range whose contents are unspecified. Two modern virtio-net NICs on a private in-process QEMU hub exchange a frame; the check verifies both used-ring completions, the entire Ethernet frame and the adjacent receive-buffer byte. The hub has no host uplink. The test process and Swift driver code execute on the Mac. QTest controls synthetic RAM and device registers: this is an independent device model test, **not** a booted Tarwin driver or an IOMMU/physical-device test.

The hosted block QTest also checks each operation's terminal LibTessera I/O packet (kind, key, status and byte count), its waiter notification and the release of its port reference. It does not emulate CPU interrupt entry or IOMMU invalidation.

On the Arm and RISC-V models the harness reads QEMU's generated DTB for the configured device topology, enumerates enabled virtio MMIO transports and probes those windows only; there is no board-specific scan address or stride fallback. On q35 the hosted PCI setup still stands in for firmware.

### q35 VT-d disk remap

    swift run -c release --package-path Tools/BlockQTest BlockQTest "$(command -v qemu-system-x86_64)" --vtd

A separate q35 run adds the Intel IOMMU model (legacy translation, no ATS). The hosted Swift backend installs a requester context for the disk only, with a random non-identity IOVA interval. The controller reads a pinned data page for the write. Before completing the client request the backend detaches that page and waits for hardware-model IOTLB invalidation with read/write draining. The disk read maps a different page at the same IOVA with device-write permission. The test checks the readback, every byte of the retired page's sentinel, the fault status, and context/IOTLB teardown before releasing the requester. This is QTest against an independent IOMMU and virtio model, **not** physical VT-d or a Tarwin guest boot.

The two-NIC check now generates IPv4/UDP with the kernel network package. The interface posts RX and paced TX on separate A.4 channels; the virtio user-driver adapter checks the queue, epoch, maximum frame and direction-specific DMA grant before creating descriptors. The independent second NIC returns the actual frame, which must pass checksum and endpoint matching and fill a registered client receive with exactly the payload. The test leaves an adjacent sentinel intact. This path has no network access outside QEMU.

In the translated q35 run, the host harness reads the model's ACPI files via fw_cfg before enabling translation. Since no BIOS runs in qtest, it applies the model's firmware-linker checksum command for DMAR. It resolves the enumerated disk requester against that table and independently checks the register page against the private q35 aperture. This exercises model firmware data, not a Tarwin ACPI boot.

For independent next-hop interoperability, repeat the three-ISA command above with `--neighbors`. One virtio NIC on QEMU's restricted user backend solicits an IPv6 router, learns its prefix, completes DAD, then sends an ARP request and an IPv6 Neighbor Solicitation (from the assigned address) to its local libslirp gateways. Both replies must validate and populate the scoped cache. No host networking, forwarding or guest boot is required.

Use `--vtd-xts` instead of `--vtd` to route the translated sector through TRFS XTS staging. Only public-vector ciphertext crosses the QTest memory boundary. Both the transferred and persisted sector must match the IEEE P1619 AES-256-XTS data-unit-255 vector, the retired page sentinel must survive, and decryption may begin only after the model IOTLB drain. CommonCrypto supplies the host AES primitive; the kernel-facing XTS transfer does not import it.

### Guest console and random-input queues

`ByteStreamQueue` serves queue 0 (console RX or entropy) or queue 1 (console TX) in a serialized user-space driver. Negotiate the isolated modern split-ring transport with no device-specific features; this console implements port zero, not MULTIPORT, resize or emergency writes. Publish only dedicated direction-limited grants prepared by the caller. Each queue bounds one outstanding span to 64 KiB, latches its completion or removal and refuses another request until synchronous retirement. Only the used input prefix is valid; a failed or malformed queue is stopped until it is rebuilt, and a pending console write is never replayed. Treat virtual RNG input as untrusted mixer input with zero entropy credit, not a key source or proof of unpredictability.

Repeat the three-ISA QTest command with `--byte-streams`. A private local pipe carries exact binary console input and output; an independent virtio-rng device returns thirteen known bytes into a larger grant, leaving the tail untouched. All files are disposable test fixtures. These checks do not boot a kernel, deliver a physical interrupt, verify IOMMU isolation for these devices or demonstrate native CSPRNG integration.

For TCP stream interoperability repeat the three-model command with `--tcp-receive`. The fixture opens a connection only to a restricted libslirp guestfwd service backed by a private binary pipe. The Tarwin active TCP connection produces the handshake, recovers three exact input chunks, retransmits a deliberately dropped outbound binary segment and gets its FIN acknowledged. It checks the timestamp/scale offers, reports the independent peer’s choices and verifies matching fallback or negotiated data options. The fixture supplies a route, ISS, timestamp offset and clock; it runs on the Mac, not in a booted guest.
