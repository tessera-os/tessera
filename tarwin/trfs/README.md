# trfs

Scoped lookup, encrypted-page staging and A.5 filesystem service records. No on-disk format, crash recovery or encryption implementation is substituted for the missing canonical TRFS specification.

Run `swift test` on macOS. For an Embedded Swift object-only check, run `SWIFTC=/path/to/swift-6.3.3/usr/bin/swiftc ../tarwin-device/check-profile.sh "$PWD"`. Host tests and cross-compiled objects do not demonstrate a booted Tarwin kernel.

## VM file-cache binding

`TrfsFilePager` implements `TarwinMM.FilePager`. Its page and lease tables use fixed storage supplied by the kernel. VM faults on the same snapshot object and aligned offset lease the same physical frame; a writable lease is exclusive. The final-page tail is zeroed at load and again when a writable mapping is released. Dirty data stays pinned in the cache until checked writeback succeeds. The VM releases a lease only after removing the mapping and completing the required TLB invalidation.

The volume-specific `TrfsPageStore` must resolve the immutable file object/extent map, authorize writable faults, supply frames from the VM, read/write only valid bytes, scrub released frames and use the encrypted staging path where applicable. Neither keys nor plaintext cache frames are passed to a block driver.

## User-space file-system servers

A server imports TarwinFsWire, not the kernel pager or VM. Each mounted volume owns a fresh 64-byte A.4 ring pair and a nonzero server epoch. Requests contain the A.5 operation, monotonically assigned ID, volume-local primary and optional secondary node, offset, and exact request-exclusive input/output share IDs and lengths. Peers exchange little-endian words. No process capability or raw address is in the record. The mount validates operation rights before submission and vouches for each share's volume, length and access direction. Server-local node numbers returned in an output share must be validated by the mount before use.

Terminal replies contain only ID, epoch, a private status and produced length. On a bad reply the session stops issuing requests and requires disconnect. On a good reply it signals ring space immediately, holds a private copy while share revocation is retried, then and only then permits cache/client delivery. An error reply cannot expose partial output. Ring-full never commits a request or takes ownership. Disconnect retries unreclaimed shares; replacement servers get new mappings. This protocol does not define TRFS's on-disk format.
