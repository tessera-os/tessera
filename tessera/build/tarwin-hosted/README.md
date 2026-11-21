# TarwindKernel

Regular Swift 6 hosted composition, with a Swift tools 6.0 manifest. The
deployment minimum is macOS 26 because the existing IPC/channel-call packages
require it. No AArch64 platform package or privileged entry path is linked.

`Tarwind.boot(_:host:)` reports time, objects, syscalls, scheduler and ready,
then calls `ready()`. Configuration paths are retained for the later storage,
image-loader and task-host stages; boot does not yet open those resources.
The MM and loader libraries are linked but do not yet map task images.

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

`installExceptionPort(process:task:)` installs a process-bound sink on a
cooperating task host's borrowed port. It maps a fault to `TaskExit(.crashed)`,
cancels that process's waits, drains its handles, removes its registry entry,
and reports through `console`, never `panic`. A kernel process has no task
port; `injectException` exercises that same registry transition in tests.

Run `swift build` and `swift test` in a complete repository checkout. With
separate Cairn mounts, set `TARWIN_SOURCE_ROOT` to the Tarwin subtree. Defaults
are repository-relative; manifests contain no machine-specific paths.
