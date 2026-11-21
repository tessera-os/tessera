# NVMe block driver

Regular Swift user-space driver for PCI NVM Express (class 01/08/02).
Start with a cold, exclusively assigned controller and five distinct, pinned 4 KiB
DMA pages. Bootstrap validates CAP and the BAR doorbell extent, starts the admin
queue, identifies the controller and active namespaces, and creates one polled
NVM I/O queue pair. Only the selected namespace is registered. Metadata,
protection information and non-512–4096-byte LBA formats are not supported.

Submit snapshots of Tarwin A.4 block records. Read, write, FUA write and flush
are supported; FUA sets the command bit and is never downgraded to a write.
Write Zeroes is enabled only by the Identify Controller ONCS bit. It takes no
data grant, leaves Deallocate clear, and writes at most one 4 KiB controller
page per command until command-set-specific write-zero limits are discovered.
Discard uses a single Dataset Management range with the Deallocate attribute,
not Write Zeroes. It requires ONCS Dataset Management and a private
device-readable page. The descriptor holds a block count, not a zero-based
count. No client buffer is mapped. Cap each request at `maxDiscardBlocks`:
the smaller of the reported single-range and total limits, or one block when
the optional NVM-specific Identify limits are unavailable. Read-only media
and out-of-bounds requests are refused before queue publication.
One- and two-page transfers use direct PRPs. For larger requests, supply
private device-readable PRP list pages at startup. Each outstanding command
owns its list until its validated completion, even after the controller has
fetched the submission. DSM descriptors share that pool and lifetime. A full
pool returns busy without touching another command's descriptor or list.
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
swift run -c release --package-path ../virtio/Tools/BlockQTest BlockQTest "$(command -v qemu-system-x86_64)" --nvme-vtd
swift run -c release --package-path ../virtio/Tools/BlockQTest BlockQTest "$(command -v qemu-system-x86_64)" --nvme-discard
```

The host discovers q35's NVMe function and its active namespace, sends a 12 KiB
FUA write through four pages in three data grants, zeroes three interior blocks,
flushes and reads back through A.4 block rings and the client port. It checks
both DMA guards and every backing-file byte. The VT-d variant binds the
enumerated NVMe requester to a private domain before enabling bus mastering.
The queues, Identify buffer, PRP list and four data pages use non-identity
IOVAs. Write consumes read-only data grants; after completion and invalidation,
read reuses the same addresses with write-only grants onto different frames.
The retired frames retain their sentinel. This is a q35 model with ATS off,
not a booted Tarwin driver or evidence of physical isolation.

The discard fixture enables backend unmap and checks QEMU's own trace: the
controller decoded one translated descriptor for exactly eight blocks at LBA
64. It checks the client completion and every backing byte outside that range.
Discard is a hint; the test does not require discarded blocks to read as zero
or establish physical flash reclamation.
