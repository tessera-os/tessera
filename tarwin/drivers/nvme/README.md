# NVMe block driver

Regular Swift user-space driver for PCI NVM Express (class 01/08/02).
Start with a cold, exclusively assigned controller and five distinct, pinned 4 KiB
DMA pages. Bootstrap validates CAP and the BAR doorbell extent, starts the admin
queue, identifies the controller and active namespaces, and creates one polled
NVM I/O queue pair. Only the selected namespace is registered. Metadata,
protection information and non-512–4096-byte LBA formats are not supported.

Submit snapshots of Tarwin A.4 block records. Read, write, FUA write and flush
are supported; FUA sets the command bit and is never downgraded to a write.
One- and two-page transfers use direct PRPs. For larger requests, supply
private device-readable PRP list pages at startup. Each outstanding command
owns its list until its validated completion, even after the controller has
fetched the submission. A full pool returns busy without touching a live list.
The first address may have a dword-aligned offset; discontiguous grants meet
only at page boundaries. The driver enforces Identify Controller's MDTS and
a 2 MiB limit (8 KiB without lists). Split larger requests above this layer;
chained PRP lists are not supported. Admin and I/O queues use 64-byte submissions,
16-byte completions and 2–64 entries. Completion is keyed by CID, not FIFO
order; phase, reported submission head and queue ID are checked before giving
the block layer a completion. A malformed completion quarantines the queue.

The transport supplies coherent, ordered MMIO/DMA access and a monotonic
clock. DeviceKit must retain the slot, domain, queue pages and all authorized
buffer grants through completion; validation must exclude physical aliases
of private pages, not just IOVA overlap. Stop admitting requests on removal or
timeout. A timeout is not evidence that DMA stopped; release pins only after
a successful controller/domain drain. Clean shutdown requires an empty queue.
No native DeviceKit launch, physical storage or power-loss durability claim.

Run `swift test` here. On macOS with QEMU installed, the independent disk-model
check runs from this directory:

```sh
swift run -c release --package-path ../virtio/Tools/BlockQTest BlockQTest "$(command -v qemu-system-x86_64)" --nvme
```

The host discovers q35's NVMe function and its active namespace, sends a 12 KiB
FUA write through four pages in three data grants, flushes and reads back through A.4 block
rings and the client port. It checks both DMA guards and every backing-file byte.
The test does not boot Tarwin or establish IOMMU coverage.
