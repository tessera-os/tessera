# Tarwin device mechanisms (26.11.1)

Use `swift test` for the portable package tests. They exercise ECAM traversal, range arithmetic, IOVA selection, retire ordering, interrupt backpressure configuration/Driver API filtering, resolved object rights and DMA quarantine. These are not tests of a booted kernel.

Integration contract:

- Run ECAM discovery from a firmware-validated segment. A faulting/absent read returns all ones. Reconcile identities and parent indices under the registry lock; a PCI function alone is not an IOMMU isolation group.
- Create slots only through DeviceRoot and only after the complete group is attached to a fresh isolated hardware domain. Refuse uncovered devices (TARWIN-D0001). Take the domain lock and supply kernel randomness and the full occupied/retiring set to the IOVA selector. A rejected sample can be retried; never fall back to identity DMA.
- Persist the retirement phase under that lock. The invalidation functions must wait for hardware completion, including all device ATCs. Do not recycle the interval or pages on timeout.
- Slot operations resolve their handle, rights and epoch before entry. Invoke the interrupt methods under the binding lock. Revocation must complete before a replacement receives an interrupt or MMIO grant.
- Configuration access policy comes from trusted enumeration, never a driver bitmap. Unknown/side-effect registers are not raw-writable. The version predicate covers released Driver API months only, starting 26.11.

A legacy Intel VT-d backend is described below; architecture interrupt entry, MMU and capability-table bindings are not supplied here. Neither DMA isolation on physical hardware nor restart timing has been measured.

## Swift profiles

Build the library as Embedded Swift; host tests run as regular Swift. IRQ delivery, revocation, range selection, DMA mapping/retirement with a caller-owned registry slab, and filtered config access can be checked separately without allocation:

```sh
SWIFTC=/path/to/swift-6.3.3/usr/bin/swiftc ./check-profile.sh
```

This emits freestanding ELF objects for arm64, x86-64, and riscv64. It neither links them into a kernel nor provides the allocator, stack guard, entropy, pinning, and device primitives needed at that boundary. Apple Xcode's compiler alone may not ship the Embedded standard library; the signed Swift.org macOS 6.3.3 release does.

Native dispatch uses the generated TarwinSyscall call constants, not new ordinals. Under the caller's object-table read epoch, resolve its slot and call `withPinnedIoHandle` with the actual table salt/index and kernel pin/release functions. It checks the live name and kind, pins the object across the borrowing closure and releases it on return. Dispatch must still bind the actual device/domain and map remaining handles under their locks. A handle snapshot alone is not a lifetime guarantee.

For PCI configuration, register `DeviceConfigCalls` as the provider for
`DeviceSlot.configRead` and `configWrite`. Register words are the slot name,
byte offset, width (1, 2 or 4), and write value for writes only. The first
result word carries a successful, zero-extended read; writes return no data.
The provider pins a typed handle in the submitting process, requires Read
or Manage respectively, and checks ownership against the slot's grant epoch.
Composition supplies the process read epoch and looks up the **retained
header** in the slot registry; hold the hotplug/config lock across validation
and the entire register transaction. Unknown or side-effect registers must
never be classified as plain writable registers.

`SlotDomainCall` implements `DeviceSlot.iommuDomain(slot)`. Its first result
word is a new Manage-only handle in the calling process, not a hardware domain
ID or an address. Record the domain binding after isolation succeeds; the
registry owns both object headers. Hold the registry, job, process and handle
writer locks across lookup and installation. A frozen registry, replaced slot
or mismatched binding cannot issue a domain handle. The call does not attach
devices or enable bus mastering; DMA creation must still validate the live
slot epoch on every mapping.

`DmaCreateCall` takes five register words: domain handle, Memory handle,
byte offset, byte length, and device access (1 = read, 2 = write, 3 = both).
It rechecks the live slot lease and Memory rights under the caller and
registry locks. Success returns a Manage-only DmaBuffer handle and the
kernel-selected IOVA in the first and second result words. Failure returns
neither. Sixteen rejected random samples yield ShouldWait, not identity DMA.

Composition supplies the locked VM extent and pin, kernel entropy, fresh
object storage and permission-limited IOMMU installation. Failed installation
must queue the private mapping for recovery. On final buffer release, retain
the original domain and payload until `retireBuffer` has detached the mapping,
completed IOTLB and device ATC invalidation, and released the pin. Coordinate
this with slot-wide teardown; a handle close by itself is not a DMA drain.
During teardown, `SlotDomain.revokeAll` seals the original group and epoch.
No mapping is detached before the requesters stop and drain. The sweep owns
all remaining entries, including failed installations with no user handle.
It reports each mapping and optional buffer KOID only after unpin, so the
object registry can finish a racing last-close without a second drain.
A timeout prevents reset and reassignment; retry resumes the stopped phase.
The device suite exercises the register dispatcher, process table and registry
with host pin/map callbacks, not a native VM, trap or physical device.

## Driver rings

A fresh pinned, cache-coherent Memory mapping contains the A.4 ring pair. Initialize it before sharing, then open exactly one lane per direction and role. The mapping is initialized as atomic words and attaches TarwinIPC RingEndpoint directly: that shared implementation owns geometry validation, private cursors, record snapshots and the idle handshake. Use a latched Event so a notification just before sleeping is retained. Any impossible peer cursor poisons the lane. Reattach only to a **new**, quiesced epoch, never reset a live ring. Device-specific records, object grants and process mappings remain the subsystem's responsibility.

## Port-bound interrupts

Arm a masked vector through `PortInterrupt` using the validated slot epoch, interrupt KOID and driver binding. A full/closed port refuses arming without unmasking. Each arm reserves one Device packet; IRQ entry acknowledges/masks before finishing it, and rearm requires a fresh credit. A cancelled or closed port never re-enables the line. Teardown must mask and drain; a failed drain keeps its reservation alive.

The kernel's `IoPorts` implementation must retain the actual port object, serialize access under its lock and wake the number of waiters returned by `TarwinIPC.CompletionPort`. Enqueue cancellation work under the port lock and execute it outside that lock, never recursively acquire the device lock. Release a retained port after recording its last buffer access and notifying waiters.

`InterruptCompleteCall` consumes the generated single-register Interrupt.complete selector. The calling process must hold Signal on the retained Interrupt and still own its IOMMU group at the original epoch. A delivered interrupt can rearm only its bound port, key and vector. If the notification port has no credit, the call returns ShouldWait without unmasking. Duplicate completion and rearm during drain are refused. The native registry owns the underlying port binding through revoke and supplies locking, trap entry and controller operations.

## Firmware MMIO discovery

`firmwareVirtioMmio` walks TarwinBoot's FDT cursor over a pinned immutable boot tree. It stages only enabled `virtio,mmio` nodes in root physical space or bounded simple-bus translations. Child and parent address cells are independent; a missing bus mapping, overlapping device windows, truncated property or ambiguous translation rejects the snapshot before probing. Per-node interrupt fields are offsets in that tree, not grants. The interrupt-controller and IOMMU owners must resolve the actual route and isolation group before slot assignment. This is not an ACPI namespace interpreter.

## Intel VT-d: legacy second-level translation

The kernel-only backend binds an isolated PCI requester to a nonzero domain with 39-bit IOVAs and 4 KiB leaves. Table memory must be exclusively owned, pinned and walker-visible; never hand those frames to a driver. Installation requires stopped requesters, ATS disabled, a supported unit and a fresh root. Bind all requester aliases under the unit lock, flush their contexts and IOTLB, verify translation is active, and only then enable DMA. There is no pass-through fallback.

Leaf permissions follow the pin's DMA direction. Clearing a leaf's permissions leaves its IOVA occupied until synchronous global IOTLB invalidation (including drain reads/writes) acknowledges. A failed invalidate quarantines it for retry. Context teardown similarly prevents requester reassignment until both caches acknowledge. The caller retains all frames, tables, domain IDs and group ownership until teardown succeeds. This profile has no device ATCs, queued invalidation, PASIDs, interrupt remapping, reserved-region/ACPI discovery, or device assignment to guests. It does not admit an ATS-capable attachment unless ATS remains disabled at the requester.

See the optional virtio QTest for a device-model readback with a fresh IOVA and a same-IOVA remap. Real platform route/group discovery, cache management, pinning, physical DMA and restart-time budgets remain unverified.

## Physical device registry

The PCI walker takes reusable scratch for all 256 bus numbers and streams
functions in parent-first order without heap allocation. A visitor may stop
the scan before another config read; discard that partial snapshot. The array
API collects the same visits. Neither API infers DMA groups from PCI ancestry.

`firmwareEcam` validates a complete, immutable ACPI MCFG before returning the
selected segment and bus window. It rejects overlapping bus claims, physical
aliases, arithmetic overflow and malformed entries anywhere in the table.
The platform independently authorizes the resulting MMIO extent. ECAM offsets
from the walker are relative to the first bus; the MCFG base is relative to
bus zero. Width, alignment, BDF and register bounds are checked per access.

On a Mac with swift.org Swift 6.3.3, QEMU's EDK II images and built EDK II
edk2-stable202408 BaseTools, set `EMBEDDED_SWIFTC`, `QEMU_FIRMWARE` and
`EDK_BASETOOLS` as for the tarboot firmware probe. Then run:

    bash tests/FirmwarePCI/run.sh

The same non-allocating Swift walk executes **inside** an unsigned EFI
diagnostic on aarch64, x86-64 and riscv64. It reads PCI config via EFI's
root-bridge protocol, finds the boot disk, and checks the RNG's parent
against the discovered bridge. With a synthetic slot binding, the guest then
reads the discovered RNG's PCI identity through the generated selector,
native register dispatcher, object table and EFI config accessor. A BAR write
and an access through the closed name must not reach that accessor. Moving
the RNG onto the root bus must fail that check. On q35 the guest also reads
MCFG from the ACPI SDT protocol, verifies its aperture against the enabled
host bridge PCIEXBAR, and independently reads the RNG identity at its
computed ECAM address via EFI CPU I/O. Both cases require a console verdict
and a guest-requested shutdown. This tests firmware access and register
dispatch, not a user trap, kernel MMIO mapping, DMA isolation, a booted
Tarwin kernel or physical hardware.

The kernel accepts a complete parent-first firmware/PCI inventory, not driver-reported MMIO, group membership or identity. The platform supplies the salted stable ID; the registry separately issues boot-local IDs that never repeat. Missing group coverage permits enumeration but never slot assignment. DeviceRoot holders may snapshot or read the latest delta; a lapped reader must take a full snapshot. This is the privileged inventory, not the public DeviceKit matching service.

Freeze admission on any topology change before resampling, under the same hardware hotplug lock that stops bus mastering. The registry invalidates each changed node, its provider descendants and every inseparable group peer. It publishes removals leaf first and additions parent first. Before replacements can acquire slots it masks interrupts, revokes CPU mappings and drains DMA for all affected groups, resetting surviving groups. Failed drain keeps grants frozen. A notification during a retry requires another snapshot before thaw. A replacement at the same physical address receives a new boot ID even when the original group number or slot epoch would otherwise match.

The q35 QTest now discovers its disk and NIC requester IDs through PCI header enumeration and a read-only registry snapshot rather than assuming device addresses. The synthetic inventory does not infer IOMMU groups from PCI addresses. Real platforms must verify ACS/alias topology and supply stable-ID generation, DeviceRoot resource lookup, hotplug notifications and synchronous group teardown. Physical hot-plug is not verified.

The legacy VT-d backend accepts a checksum-valid ACPI DMAR revision 1 describing one DRHD register page for the selected segment. A direct endpoint scope must match the requester unless the segment is explicitly covered by INCLUDE_PCI_ALL. IOAPIC and HPET scopes cannot grant DMA access. The platform must independently confirm that the page is reserved as register memory. Ambiguous coverage, multiple units, bridge paths, reserved-memory requests (RMRR) and unsupported flags or structures are rejected; there is no identity fallback. This is not full ACPI namespace enumeration or hardware group discovery.
