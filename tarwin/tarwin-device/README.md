# Tarwin device mechanisms (26.11.1)

Use `swift test` for the portable package tests. They exercise ECAM traversal, range arithmetic, IOVA selection, retire ordering, interrupt backpressure configuration/Driver API filtering, resolved object rights and DMA quarantine. These are not tests of a booted kernel.

Integration contract:

- Run ECAM discovery from a firmware-validated segment. A faulting/absent read returns all ones. Reconcile identities and parent indices under the registry lock; a PCI function alone is not an IOMMU isolation group.
- Create slots only through DeviceRoot and only after the complete group is attached to a fresh isolated hardware domain. Refuse uncovered devices (TARWIN-D0001). Take the domain lock and supply kernel randomness and the full occupied/retiring set to the IOVA selector. A rejected sample can be retried; never fall back to identity DMA.
- Persist the retirement phase under that lock. The invalidation functions must wait for hardware completion, including all device ATCs. Do not recycle the interval or pages on timeout.
- Slot operations resolve their handle, rights and epoch before entry. Invoke the interrupt methods under the binding lock. Revocation must complete before a replacement receives an interrupt or MMIO grant.
- Configuration access policy comes from trusted enumeration, never a driver bitmap. Unknown/side-effect registers are not raw-writable. The version predicate covers released Driver API months only, starting 26.11.

No architecture interrupt, IOMMU, MMU, registry service or capability table is supplied by this package yet. Neither DMA isolation on physical hardware nor restart timing has been measured.

## Swift profiles

Build the library as Embedded Swift; host tests run as regular Swift. IRQ delivery, revocation, range selection, DMA mapping/retirement with a caller-owned registry slab, and filtered config access can be checked separately without allocation:

```sh
SWIFTC=/path/to/swift-6.3.3/usr/bin/swiftc ./check-profile.sh
```

This emits freestanding ELF objects for arm64, x86-64, and riscv64. It neither links them into a kernel nor provides the allocator, stack guard, entropy, pinning, and device primitives needed at that boundary. Apple Xcode's compiler alone may not ship the Embedded standard library; the signed Swift.org macOS 6.3.3 release does.

Native dispatch uses the generated TarwinSyscall call constants, not new ordinals. Under the caller's object-table read epoch, resolve its slot and call `withPinnedIoHandle` with the actual table salt/index and kernel pin/release functions. It checks the live name and kind, pins the object across the borrowing closure and releases it on return. Dispatch must still bind the actual device/domain and map remaining handles under their locks. A handle snapshot alone is not a lifetime guarantee.

## Driver rings

A fresh pinned, cache-coherent Memory mapping contains the A.4 ring pair. Initialize it before sharing, then open exactly one lane per direction and role. The mapping is initialized as atomic words and attaches TarwinIPC RingEndpoint directly: that shared implementation owns geometry validation, private cursors, record snapshots and the idle handshake. Use a latched Event so a notification just before sleeping is retained. Any impossible peer cursor poisons the lane. Reattach only to a **new**, quiesced epoch, never reset a live ring. Device-specific records, object grants and process mappings remain the subsystem's responsibility.

## Port-bound interrupts

Arm a masked vector through `PortInterrupt` using the validated slot epoch, interrupt KOID and driver binding. A full/closed port refuses arming without unmasking. Each arm reserves one Device packet; IRQ entry acknowledges/masks before finishing it, and rearm requires a fresh credit. A cancelled or closed port never re-enables the line. Teardown must mask and drain; a failed drain keeps its reservation alive.

The kernel's `IoPorts` implementation must retain the actual port object, serialize access under its lock and wake the number of waiters returned by `TarwinIPC.CompletionPort`. Enqueue cancellation work under the port lock and execute it outside that lock, never recursively acquire the device lock. Release a retained port after recording its last buffer access and notifying waiters.
