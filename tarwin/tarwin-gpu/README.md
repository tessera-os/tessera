# tarwin-gpu

GPU memory charging, timeline fence donation and doorbell grants. No Ember, display-server or hardware integration is implied.

Run `swift test` on macOS. For an Embedded Swift object-only check, run `SWIFTC=/path/to/swift-6.3.3/usr/bin/swiftc ../tarwin-device/check-profile.sh "$PWD"`. Host tests and cross-compiled objects do not demonstrate a booted Tarwin kernel.

Fence waiters use preallocated, caller-owned storage. The profile check also compiles signal, cancellation and priority donation with `-no-allocations` for each target.

`FenceObject` binds the execution owner's generated Fence.wait/signal numbers to a type-32 object through the caller's epoch-protected HandleReadView. A transferred, rights-reduced handle addresses the same timeline, not a DeviceKit token. Wait requires Wait; signal requires Signal. Each blocked thread holds a distinct object reference and a fence-local ticket; cancellation is exact, and unplug wakes outstanding tickets with deviceRemoved. A release store to the coherent timeline word precedes wakes. Donation follows the highest remaining wait priority.

The bootstrap must supply the payload and IRQ-safe lock, read epoch, coherent read-only mapping, and nonblocking scheduler park/wake hooks. The tests use the real handle table and object transfer but a host scheduler observer, not a blocked kernel thread, GPU interrupt or device-visible memory test.

Each serial presentation queue binds a presenting process, driver process and slot epoch to a scheduler work interval. After reserving a command, the presenter starts the interval; the driver receives the same monotonic deadline in the frame ticket. Actual CPU slices train the scheduler's estimate, which affects placement only for registered driver workers. Thermal ceilings still apply on a missed deadline. Slot retirement discards the group and invalidates outstanding frame tickets. The queue uses caller-owned member storage and the non-allocating profile.

The integration test exercises Tarwin's scheduler placement policy on the Mac. It does not run Ember, program a display, measure a frame or prove a native scheduling deadline.
