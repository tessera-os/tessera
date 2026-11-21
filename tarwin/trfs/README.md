# trfs

Scoped lookup, encrypted-page staging and A.5 filesystem service records. No on-disk format, crash recovery or encryption implementation is substituted for the missing canonical TRFS specification.

Run `swift test` on macOS. For an Embedded Swift object-only check, run `SWIFTC=/path/to/swift-6.3.3/usr/bin/swiftc ../tarwin-device/check-profile.sh "$PWD"`. Host tests and cross-compiled objects do not demonstrate a booted Tarwin kernel.

## VM file-cache binding

`TrfsFilePager` implements `TarwinMM.FilePager`. Its page and lease tables use fixed storage supplied by the kernel. VM faults on the same snapshot object and aligned offset lease the same physical frame; a writable lease is exclusive. The final-page tail is zeroed at load and again when a writable mapping is released. Dirty data stays pinned in the cache until checked writeback succeeds. The VM releases a lease only after removing the mapping and completing the required TLB invalidation.

The volume-specific `TrfsPageStore` must resolve the immutable file object/extent map, authorize writable faults, supply frames from the VM, read/write only valid bytes, scrub released frames and use the encrypted staging path where applicable. Neither keys nor plaintext cache frames are passed to a block driver.
