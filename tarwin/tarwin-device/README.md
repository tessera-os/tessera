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

The generated native dispatcher must map its call index to `DeviceOperation` and pin a validated handle-table entry, checking the caller, name, generation and rights before supplying `PinnedIoHandle`. These Swift enum tags have no ABI ordinal.
