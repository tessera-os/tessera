# tarwin-gpu

GPU memory charging, timeline fence donation and doorbell grants. [MosaicDisplay v1](MosaicDisplay.md) specifies the Metal presentation path; the user-space driver lives in [drivers/tvgpu](../drivers/tvgpu).

Run `swift test` on macOS. For an Embedded Swift object-only check, run `SWIFTC=/path/to/swift-6.3.3/usr/bin/swiftc ../tarwin-device/check-profile.sh "$PWD"`. Host tests and cross-compiled objects do not demonstrate a booted Tarwin kernel.

The [device provider](../tarwin-device/Sources/TarwinDevice/DoorbellMappings.swift)
owns the revocable form of a doorbell grant. The registry binds it to an
enumerated aperture and group lease; a hotplug freeze immediately stops new
grants and a failed unmap keeps the replacement node unpublished. The
[register provider](../tarwin-device/Sources/TarwinDevice/DoorbellCall.swift)
takes the range handle, destination process handle and byte offset, in that
order, and returns status only. It checks the live slot, the exact Map+Manage
MMIO range and a Manage handle to the destination process. Its
preallocated page records retain each process until unmap and CPU translation
invalidation both finish. A partially installed mapping closes the range to new
grants; the VM must quarantine partial installs and schedule teardown before
returning. Mac tests dispatch all three register layouts and replace a GPU in
the hardware registry. The native trap and VM mapping implementation
are still needed: a platform unable to enforce write-only, uncached and NX
must refuse the mapping, not substitute read/write access.

Use a single [DoorbellResources](../tarwin-device/Sources/TarwinDevice/DoorbellResources.swift)
under the registry, process and VM locks. Bind ranges before publishing their
handles; a second binding for the same aperture is refused. The same table
serves the grant call and the registry's teardown provider. It retains each
range header until its client mappings drain. The device profile compiles
concrete grant and unmap paths with indirect VM callbacks under
`-no-allocations`; it does not implement those callbacks.

Fence waiters use preallocated, caller-owned storage. The profile check also compiles signal, cancellation and priority donation with `-no-allocations` for each target.

`FenceObject` binds the execution owner's generated Fence.wait/signal numbers to a type-32 object through the caller's epoch-protected HandleReadView. A transferred, rights-reduced handle addresses the same timeline, not a DeviceKit token. Wait requires Wait; signal requires Signal. Each blocked thread holds a distinct object reference and a fence-local ticket; cancellation is exact, and unplug wakes outstanding tickets with deviceRemoved. A release store to the coherent timeline word precedes wakes. Donation follows the highest remaining wait priority.

The bootstrap must supply the payload and IRQ-safe lock, read epoch, coherent read-only mapping, and nonblocking scheduler park/wake hooks. The tests use the real handle table and object transfer but a host scheduler observer, not a blocked kernel thread, GPU interrupt or device-visible memory test.

Each serial presentation queue binds a presenting process, driver process and slot epoch to a scheduler work interval. After reserving a command, the presenter starts the interval; the driver receives the same monotonic deadline in the frame ticket. Actual CPU slices train the scheduler's estimate, which affects placement only for registered driver workers. Thermal ceilings still apply on a missed deadline. Slot retirement discards the group and invalidates outstanding frame tickets. The queue uses caller-owned member storage and the non-allocating profile.

The integration test exercises Tarwin's scheduler placement policy on the Mac. It does not program a physical display, measure a frame or prove a native scheduling deadline.

GPU allocation attribution binds a unique allocation payload (system or device-local memory) to a process member. Under the job and accounting locks, an authenticated driver must present a live Manage handle for that exact process. Charging combines the synchronized non-GPU footprint with the new GPU total and reserves it through the job tree before the allocation can be published. Ancestor quota failure leaves both the ledger and allocation untouched. CPU mappings and aliases share the payload; neither handle closure nor a failed retirement acknowledgement refunds a charge. Drain charges before detaching the process. The memory owner supplies non-GPU accounting, unique payloads and terminal CPU/DMA retirement; hardware and native provider composition are not tested here.
