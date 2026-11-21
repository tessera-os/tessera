# trfs

Scoped lookup, encrypted-page staging and A.5 filesystem service records. No on-disk format, crash recovery or encryption implementation is substituted for the missing canonical TRFS specification.

Run `swift test` on macOS. For an Embedded Swift object-only check, run `SWIFTC=/path/to/swift-6.3.3/usr/bin/swiftc ../tarwin-device/check-profile.sh "$PWD"`. Host tests and cross-compiled objects do not demonstrate a booted Tarwin kernel.

## VM file-cache binding

`TrfsFilePager` implements `TarwinMM.FilePager`. Its page and lease tables use fixed storage supplied by the kernel. VM faults on the same snapshot object and aligned offset lease the same physical frame; a writable lease is exclusive. The final-page tail is zeroed at load and again when a writable mapping is released. Dirty data stays pinned in the cache until checked writeback succeeds. The VM releases a lease only after removing the mapping and completing the required TLB invalidation.

The volume-specific `TrfsPageStore` must resolve the immutable file object/extent map, authorize writable faults, supply frames from the VM, read/write only valid bytes, scrub released frames and use the encrypted staging path where applicable. Neither keys nor plaintext cache frames are passed to a block driver.

## User-space file-system servers

A server imports TarwinFsWire, not the kernel pager or VM. Each mounted volume owns a fresh 64-byte A.4 ring pair and a nonzero server epoch. Requests contain the A.5 operation, monotonically assigned ID, volume-local primary and optional secondary node, offset, and exact request-exclusive input/output share IDs and lengths. Peers exchange little-endian words. No process capability or raw address is in the record. The mount validates operation rights before submission and vouches for each share's volume, length and access direction. Server-local node numbers returned in an output share must be validated by the mount before use.

Terminal replies contain only ID, epoch, a private status and produced length. On a bad reply the session stops issuing requests and requires disconnect. On a good reply it signals ring space immediately, holds a private copy while share revocation is retried, then and only then permits cache/client delivery. An error reply cannot expose partial output. Ring-full never commits a request or takes ownership. Disconnect retries unreclaimed shares; replacement servers get new mappings. This protocol does not define TRFS's on-disk format.

The VM resolver also returns the canonical backing object and backing-relative byte interval for each share. The mount rejects overlaps between distinct IDs (including input versus output in a single request), wrong volume or direction, and wrapped ranges. A failed revoke keeps the interval reserved. The backing metadata is kernel-private and does not change the A.5 record.

### Removable FAT16 server

TarwinFAT is regular Swift in user space. It accepts only a pinned, immutable partition view (reads must fail on media replacement), initializes volume-local nodes from the FAT16 BPB, short-name directories and validated cluster chains, and refuses cross-linked, cyclic, truncated, inconsistent mirrored or out-of-range allocation metadata. It indexes at most 65,536 nodes and scans at most 1,048,576 directory records. Reads are bounded to 1 MiB and stop at the file's exact byte length.

One FatServer per fresh mount consumes A.5 requests and publishes replies on the opposite half of its ring. Lookup accepts one ASCII 8.3 name and returns an eight-byte little-endian volume node ID. Attributes and directory iteration return one private FsEntry, not a public NodeInfo; the directory offset is a zero-based index and zero bytes means end. The server also supports read, sync and flush. Mutations return read-only. A full reply ring retains one private reply and never repeats the share write. Names cannot walk to parents. VFAT long names, FAT12/32, exFAT, writable mounts, media hotplug and a native process launcher are not implemented here.

With mtools on PATH, the package tests format an independent FAT16 image, populate a nested file and read its exact contents through the A.5 server and mount endpoints. Without mtools this integration case is skipped (not a pass); the in-memory fragmented media and malformed-chain cases still run. This is not an on-disk TRFS format or a guest boot.
