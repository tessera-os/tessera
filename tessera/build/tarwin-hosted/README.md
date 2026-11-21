# TarwindKernel

Regular Swift 6 hosted composition, with a Swift tools 6.0 manifest. The
deployment minimum is macOS 26 because the existing IPC/channel-call packages
require it. No AArch64 platform package or privileged entry path is linked.

`Tarwind.boot(_:host:)` reports time, objects, syscalls, storage, network,
scheduler and ready, then calls `ready()`. The disk path is opened and mounted;
only a missing disk is created and formatted (256 MiB sparse bootstrap size).
An existing damaged disk fails, never reformats. Shutdown unmounts by releasing
the volume and its block device, even while the Tarwind object remains retained.
The MM and loader libraries are linked but do not yet map task images; the panic
record and task executable paths remain reserved.

An existing system image requires the host to conform to the additive
`TarwindSystemVolumeVerifier` protocol, supplying the trusted 32-byte boot-set
root and measurement callback. `HostedTrfsDisk.openSystem` verifies and mounts
read-only, with no fallback on verification failure. A missing image is optional.
The frozen configuration and host protocol are unchanged; no trust root is
inferred from the untrusted image. `withDataVolume` and `withSystemVolume` expose
serialized TRFS operations; their callbacks must not reenter the kernel.

`shareFolder` duplicates the caller's directory descriptor, transferring only
the duplicate to HostFolderVolume. `makeFolderServer` supplies a HostFolderServer
ring service. The caller owns the ring storage and shares until the server is
stopped; callbacks must not reenter the kernel. Unshare stops all retained servers
and releases the volume, and duplicate names throw. There is no generated
filesystem/namespace CallProvider wired into this gate: TRFS has a lower-level
MountedRead bridge requiring ProcessExecution, staged shares and IoPorts, not
the existing kernel-process gate. Storage therefore stops at these tested APIs,
without inventing a competing File.read syscall implementation.

The default network policy explicitly allows all flows. Connect/listen/accept
and datagram creation register their socket descriptors with the kernel event
queue. Each returned TarwindSocket publishes a wait-only readiness handle:
Object.wait masks 1/2/4 mean readable/writable/closed. Events complete the real
object wait queue; nonblocking send/receive rearm readiness. Close, process fault
and shutdown cancel registrations before closing descriptors. This is bootstrap
policy, not per-application network isolation or a network syscall bank.

`boot(_:host:devices:)` retains the app's HostDeviceRegistry; the original overload
uses an empty one. H6's HID/audio/power providers expose Mach send rights to
retained in-process TWHD driver inboxes. `openHostDevice(process:kind:slot:)`
validates a live process and forwards provider.open, returning its owned HostPort
unchanged for H6's HostedDriverEndpoint transport. They are not PCI/IOMMU DeviceKit
slots, so no synthetic slot/config/DMA authority is minted. The registry exposes
lookup, not enumeration; matching is by the provider's exact kind. H7 still owns
driver instantiation, return channels and app feed serialization.

`kernel.gate.call(process:registers:)` uses `TarwinABI.CallRegisters` and
`CallResult` inside a call-number envelope. Completed results also update the
ABI return words. `blocked(id)` leaves no Swift stack or host thread parked;
`gate.completion(id)` consumes its result after wake, timeout or cancellation.
`gate.cancel(id)` races through the same generation-checked AddressQueue ticket.

Kernel processes have independent handle tables and no OS task. The gate
uses a private diagnostic origin, as existing register-gate probes do; it is
not a substitute for validating a task's loaded LibTessera trap sites.
Only buffers returned by `allocateKernelBuffer(process:count:)` are accepted
for kernel-process copies. Callers must serialize their direct buffer access
with gate operations. A task gate must add a separate pinned-copy backend.

One kernel lock serializes registry, object, handle and wait transitions.
Object-signal and physical-address waits use separate queues/key spaces.
Headers remain mapped in the kernel arena through shutdown, providing a
whole-kernel storage epoch; final-reference callbacks still destroy endpoint
semantics immediately. Queue callbacks never free storage or reenter a queue.
Kernel processes are capped at 64, handle tables at 256 slots, object headers
at 1024, and simultaneous waits at 64. These are hosted bootstrap quotas.

The time page uses HostClock awake nanoseconds as a calibrated 1 GHz counter
domain. A HostEventQueue timer drives TarwinTime deadline delivery and
TarwinSched BootstrapCPU accounting on one kernel worker. OS suspend/resume
notifications and trusted UTC initialization remain future power/time-service
integration; UTC reads fail closed until then. No guest scheduling contexts
exist yet. The worker's initial class and bound host-thread class changes use
`applyHostedSchedulingChange`, supplied a scheduler-owned dispatch key;
tests exercise live background/default/interactive transitions and refusal
of an invalid realtime budget.

`installExceptionPort(process:task:pager:)` installs a process-bound sink on a
cooperating task host's borrowed port; its optional pager defaults to nil.
`makeExceptionSendRight(process:pager:)` retains the receive service and returns
an owned send right for H2's spawner. The synchronous pager receives the original
HostException outside the kernel lock. A resume disposition replies without
recording a crash; nil, throw or terminate falls through to fatal handling.
The pager must not wait for the faulting thread. Fatal handling maps to `TaskExit(.crashed)`,
cancels that process's waits, drains its handles, removes its registry entry,
and reports through `console`, never `panic`. A kernel process has no task
port; `injectException` exercises that same registry transition in tests.

Run `swift build` and `swift test` in a complete repository checkout. With
separate Cairn mounts, set `TARWIN_SOURCE_ROOT` to the Tarwin subtree. Defaults
are repository-relative; manifests contain no machine-specific paths.
