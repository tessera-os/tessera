# trfs

Scoped lookup, encrypted-page staging and A.5 filesystem service records. No on-disk format or crash recovery is inferred from Tarwin.

Run `swift test` on macOS. For an Embedded Swift object-only check, run `SWIFTC=/path/to/swift-6.3.3/usr/bin/swiftc ../tarwin-device/check-profile.sh "$PWD"`. Host tests and cross-compiled objects do not demonstrate a booted Tarwin kernel.

## VM file-cache binding

`TrfsFilePager` implements `TarwinMM.FilePager`. Its page and lease tables use fixed storage supplied by the kernel. VM faults on the same snapshot object and aligned offset lease the same physical frame; a writable lease is exclusive. The final-page tail is zeroed at load and again when a writable mapping is released. Dirty data stays pinned in the cache until checked writeback succeeds. The VM releases a lease only after removing the mapping and completing the required TLB invalidation.

The volume-specific `TrfsPageStore` must resolve the immutable file object/extent map, authorize writable faults, supply frames from the VM, read/write only valid bytes, scrub released frames and use the encrypted staging path where applicable. Neither keys nor plaintext cache frames are passed to a block driver.

### Software-encrypted block transfers

`XtsSector` applies AES-256-XTS to a whole data unit of 16-byte blocks (at most 16 MiB). The volume supplies the block address, data-unit number and pinned key-object identity; the trusted CPU backend supplies the tweak and data AES-256 schedules. Data-unit numbering, on-disk allocation and key lifecycle are not defined by this adapter. XTS provides confidentiality, not integrity or crash recovery.

Only the disjoint ciphertext staging range reaches the driver. The caller owns both physical pins and excludes other cache clients until the transfer completes. A short/error completion cannot be upgraded by a retry; while DMA revocation fails, neither span is touched. Once revocation succeeds the staging span is scrubbed; failed reads also scrub the whole cache span. Use a non-elidable erase primitive and proper DMA cache maintenance at native composition.

The sector path compiles with `-no-allocations` for all three targets. The q35 `--vtd-xts` check in the virtio package uses host CommonCrypto for the single-block AES primitive, requires the IEEE P1619 known-answer ciphertext on disk and recovers the full plaintext after revocation. It is not a native kernel AES implementation, boot, authenticated filesystem or physical disk test.

## User-space file-system servers

A server imports TarwinFsWire, not the kernel pager or VM. Each mounted volume owns a fresh 64-byte A.4 ring pair and a nonzero server epoch. Requests contain the A.5 operation, monotonically assigned ID, volume-local primary and optional secondary node, offset, and exact request-exclusive input/output share IDs and lengths. Peers exchange little-endian words. No process capability or raw address is in the record. The mount validates operation rights before submission and vouches for each share's volume, length and access direction. Server-local node numbers returned in an output share must be validated by the mount before use.

Terminal replies contain only ID, epoch, a private status and produced length. On a bad reply the session stops issuing requests and requires disconnect. On a good reply it signals ring space immediately, holds a private copy while share revocation is retried, then and only then permits cache/client delivery. An error reply cannot expose partial output. Ring-full never commits a request or takes ownership. Disconnect retries unreclaimed shares; replacement servers get new mappings. This protocol does not define TRFS's on-disk format.

The VM resolver also returns the canonical backing object and backing-relative byte interval for each share. The mount rejects overlaps between distinct IDs (including input versus output in a single request), wrong volume or direction, and wrapped ranges. A failed revoke keeps the interval reserved. The backing metadata is kernel-private and does not change the A.5 record.

### Read-only removable FAT16 and FAT32 server

For a positional File.read on an A.5 mount, `MountedRead.begin` resolves the caller's File with Read and Port with Write, then reserves an Io completion tagged with the caller's process KOID and the exact File handle. Serialize registration with handle invalidation. The close path cancels by this pair, not by object, port key or slot number: closing a duplicate must not cancel the original read. File and port references and buffer pins remain live until the backend retires its share, even after cancellation. Only the trusted File payload supplies the volume, mount generation and local node. The request refers to a private staging share, not the client's writable destination.

The mount issues an `FsReceipt` only after revoking the server's access. The worker matches the exact volume, generation and request, then commits just the reported prefix to the destination. The commit must be bounded, nonfaulting and all-or-nothing under the port lock. On cancellation, closed port, lost mount or server error, staging is discarded; the client never receives the private bytes. An unpublished request can be abandoned after draining its grant. Tests use real handle tables, completion ports, A.5 rings and independently formatted FAT16 and FAT32 media. User-iovec pinning, the syscall trap/provider and a canonical TRFS disk implementation are not supplied by this adapter.

TarwinFAT is regular Swift in user space. It accepts only a pinned, immutable partition view (reads must fail on media replacement), initializes volume-local nodes from the partition geometry, short-name directories and validated cluster chains, and refuses cross-linked, cyclic, truncated, inconsistent mirrored or out-of-range allocation metadata. FAT32 supports chained roots, 28-bit cluster links and a selected active FAT when mirroring is disabled. Only the low 28 bits of mirrored entries must agree; free-space hints are never authoritative. Unclean or unsupported allocation metadata is rejected rather than repaired. The mount admits at most 1,048,576 clusters, indexes at most 65,536 nodes and scans at most 1,048,576 directory records. Reads are bounded to 1 MiB and stop at the file's exact byte length.

One FatServer per fresh mount consumes A.5 requests and publishes replies on the opposite half of its ring. Lookup accepts one ASCII 8.3 name and returns an eight-byte little-endian volume node ID. Attributes and directory iteration return one private FsEntry, not a public NodeInfo; the directory offset is a zero-based index and zero bytes means end. The server also supports read, sync and flush. Mutations return read-only. A full reply ring retains one private reply and never repeats the share write. Names cannot walk to parents. VFAT long names, FAT12, writable mounts, media hotplug and a native process launcher are not implemented here.

With mtools on PATH, the package tests format FAT16 and FAT32 images, populate a nested file on each and read its exact contents through the A.5 server and mount endpoints. Without mtools this integration case is skipped (not a pass); the in-memory fragmented media and malformed-chain cases still run. This is not an on-disk TRFS format or a guest boot.

### Read-only archive views

TarwinArchive serves uncompressed POSIX ustar regular files and directories from an immutable image. It validates header checksums, octal sizes, padded extents and the two-block trailer before publishing the root. Paths (including ustar prefixes) build a byte-exact, case-sensitive UTF-8 index, not host filesystem paths. Missing parent directories are implicit; duplicate declarations, parent traversal, absolute paths, ambiguous components and file/directory collisions reject the mount. Links, special files, GNU extensions, PAX records and compressed streams are unsupported, not followed or extracted.

The mount admits at most 65,536 headers and nodes (including the root), 64 path components, 1 MiB of trailing zero records after the first end block, and 1 MiB per read. The read-only A.5 server, share retirement and typed mounted File.read path are shared with FAT. On macOS the tests build a nested archive independently with bsdtar and read binary contents through that path. This is a user-space archive view, not canonical TRFS.

### Read-only exFAT removable media

TarwinExFAT serves a pinned, immutable exFAT 1.00 partition using the same A.5 server and mounted File.read path. The [Microsoft format specification](https://learn.microsoft.com/en-us/windows/win32/fileio/exfat-specification) defines both checksummed boot regions, the allocation bitmap, the volume-specific up-case table and stream entry sets. The mount checks both boot regions, FAT and heap geometry, stream checksums, name hashes and case-folded directory uniqueness before publishing the root. Volume-local reads follow either an exact FAT chain or a contiguous allocation. Bytes between ValidDataLength and DataLength are synthesized as zeros, never copied from media.

This profile accepts clean single-FAT volumes only. It rejects unknown live metadata, cyclic or cross-linked allocations, invalid UTF-16, and names that exceed the A.5 limit of 255 UTF-8 bytes. Limits are 1,048,576 clusters, 1 MiB per cluster or read, 16 MiB of directory data and 65,536 nodes. It does not implement writes, TexFAT, repair or canonical TRFS. Mac tests generate a populated partition with hdiutil and read a nested Unicode-named file through File.read; a modified fixture exercises a fragmented stream and an uninitialized tail.
