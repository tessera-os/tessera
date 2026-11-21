# tarwin-block

Block scheduling, QoS bypass, barriers, replay epochs and removal. Hardware queue transport and timing are not verified.

Run `swift test` on macOS. For an Embedded Swift object-only check, run `SWIFTC=/path/to/swift-6.3.3/usr/bin/swiftc ../tarwin-device/check-profile.sh "$PWD"`. Host tests and cross-compiled objects do not demonstrate a booted Tarwin kernel.

## Block driver channel (26.11, A.4)

`BlockQueue.publish` issues a request only after publication to the shared TarwinIPC ring succeeds. Completions must match the queue, driver epoch and an issued request. Protected payload grants are resolved again on replay; a restarted driver never inherits old IOVAs. The user driver imports the data-only `TarwinBlockWire` product, not the scheduler.

Each 64-byte request is little endian. Word 0 holds version 1 (low 16), opcode and QoS (8 each); word 1 is zero. Request id, epoch, LBA, block count and vector-list IOVA are consecutive u64s at byte 8. List count, queue, zone action and zero occupy the final four u32s. An element is a u64 IOVA, u32 length and zero u32. A device must check total length, direction and current-domain grants, including the vector list. Completion word 0 holds version and status, word 1 the queue, followed by the request id and epoch. Unused words, including the tail on a 128-byte ring, are zero. The wire enums are train-private and distinct from syscall numbers.

Geometry and feature limits gate flush, FUA, discard, zero, atomic-unit and whole-zone operations. There is no downgrade from FUA/atomic to an ordinary write. The baseline virtio service currently registers single-vector reads and writes plus negotiated flush, single-range discard and write-zeroes. The package-local QTest in the guest driver drives this scheduler/driver exchange against a QEMU disk; it is not a Tarwin boot or a performance gate.

## Client completion ports

`PortBlockQueue` binds the driver scheduler to one-shot LibTessera I/O packets. Submission reserves a credit on the caller's retained port before exposing work to the driver. Backpressure returns no request ID. Dispatch and driver reply validation use the same queue and epoch; only a successful buffer retirement releases the credit into the port. Out-of-order driver replies stay ordered per client object on its port. Port closure discards packets, not outstanding DMA.

When draining a failed backend, stop publication first. Do not replay finished or cancelled operations. A failed drain or failed buffer retirement retains the pending references for retry. Remaining operations replay after an epoch change; permanent removal delivers DeviceLost at the public ABI. Integration still needs the kernel's real port-object lookup, locks, pinning and wakeup providers.
