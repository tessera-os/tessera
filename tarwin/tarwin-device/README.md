# Tarwin device mechanisms (26.11.1)

Use `kira test .` for the portable package tests. They exercise ECAM traversal, range arithmetic, IOVA selection, retire ordering, interrupt backpressure and configuration/Driver API filtering. These are not tests of a booted kernel.

Integration contract:

- Run ECAM discovery from a firmware-validated segment. A faulting/absent read returns all ones. Reconcile identities and parent indices under the registry lock; a PCI function alone is not an IOMMU isolation group.
- Create slots only through DeviceRoot and only after the complete group is attached to a fresh isolated hardware domain. Refuse uncovered devices (TARWIN-D0001). Take the domain lock and supply kernel randomness and the full occupied/retiring set to the IOVA selector. A rejected sample can be retried; never fall back to identity DMA.
- Persist the retirement phase under that lock. The invalidation functions must wait for hardware completion, including all device ATCs. Do not recycle the interval or pages on timeout.
- Slot operations resolve their handle, rights and epoch before entry. Invoke the interrupt methods under the binding lock. Revocation must complete before a replacement receives an interrupt or MMIO grant.
- Configuration access policy comes from trusted enumeration, never a driver bitmap. Unknown/side-effect registers are not raw-writable. The version predicate covers released Driver API months only, starting 26.11.

No architecture interrupt, IOMMU, MMU, registry service or capability table is supplied by this package yet. Neither DMA isolation on physical hardware nor restart timing has been measured.
