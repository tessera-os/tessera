# Tarwin Hosted: Tessera on macOS without a virtual machine

Date: 2026-11-21. Tarwin version: 26.11.1. Status: normative draft 0.1. Audience: agents building Tessera.app, the hosted Tarwin kernel and the LibTessera to libSystem/XNU translation under it.

This document extends [Tarwin.md](Tarwin.md). Where it is silent, Tarwin.md applies. SpringBoard and the system UI are specified elsewhere; this document gives them a display, input and a running userland.

## 1. Goal

Tessera.app is a macOS application for Apple silicon Macs running macOS 26 or later. Opening it boots Tessera: Tarwin runs as an ordinary macOS process, every Tessera process is an ordinary macOS process, and every LibTessera program runs unchanged. There is no virtual machine, no QEMU, no Linux kernel and no Hypervisor.framework guest.

Ends when: an unmodified, signed aarch64 Tarwin image of `tessera.init`, the system services, MosaicDisplay and the desktop boots inside Tessera.app, draws in its window through Metal, takes keyboard, pointer and audio, reads and writes its own TRFS disk, reaches the network, and the hosted runs of the section 34 object, IPC, memory, loader and storage suites pass.

## 2. Terms

| Term | Meaning |
| --- | --- |
| Hosted Tarwin | Tarwin's kernel subsystems built as regular Swift for macOS, over the hosted platform layer instead of an ISA layer |
| `tarwind` | The macOS process that is the hosted kernel. One per running Tessera |
| Task | The macOS process that holds one Tessera process: its address space, threads and the task host |
| Task host | The small Embedded Swift runtime in every task that maps memory, starts threads and forwards system calls on `tarwind`'s instructions |
| Gate | How a Tessera thread enters `tarwind`: the hosted replacement for `svc #0` |
| Translator | The hosted platform layer, the task host and the gate together: they turn each Tarwin mechanism into libSystem and XNU calls |

## 3. Decisions

| Id | Decision | Reason |
| --- | --- | --- |
| HS-001 | The kernel stays the kernel: objects, handles, rights, IPC, scheduling policy, the loader, code-signing checks, TRFS and the network stack run in `tarwind`, from the same Tarwin packages. Only layer 0 (section 36.1) is replaced, by `tarwin-arch-hosted`. | One kernel to test. LibTessera keeps the "native kernel" column of LibTessera.md section 21.4: rights are enforced by `tarwind`, never by the app. |
| HS-002 | One Tessera process is one macOS process (the task). | XNU address-space isolation replaces page tables; a crashed app takes down only its task. |
| HS-003 | LibTessera apps run as their signed Tarwin ELF images. The task host maps them; nothing is relinked as Mach-O. | "Every LibTessera app works out of the box": the same image runs on hardware Tarwin and in Tessera.app. |
| HS-004 | The gate is a combined `mach_msg` send and receive on the task's kernel port, with a send-once reply right. Arguments and results use the register layout of Tarwin.md section 10.2 in the message body. A blocking call is answered when it completes; it holds no `tarwind` thread meanwhile. | One XNU trap per call, as on hardware; blocking does not exhaust a thread pool. |
| HS-005 | `svc #0` sites are rewritten at load. The loader reads the image's trap-site table (TVISA.md section 17.10) and patches each site to a branch to the gate stub before code is made executable. A `svc` not in the table raises SIGSYS in the task; the task host treats it as a Tarwin fatal exception (section 11.4), never as a system call. | Unmodified images; an unlisted trap cannot reach XNU or `tarwind` unchecked. |
| HS-006 | Port rings (Tarwin.md section 10.5), the time page and all shared memory are macOS shared memory (`mach_make_memory_entry_64`) mapped into the task by the task host. Steady-state ring I/O makes no gate call, as on hardware. | Keeps Tarwin's "no system call in steady state" goal. |
| HS-007 | `tarwind` never asks for another task's task port. The task host maps, protects, unmaps and starts threads in its own task on `tarwind`'s instruction, over the task's command port. `tarwind` trusts nothing the task host reports. | Works under the hardened runtime and SIP. A hostile task can only misuse memory entries it was sent, which already carry their rights. |
| HS-008 | Every task runs under a generated `sandbox_init` profile: no file system, no network, no Mach lookups except `tarwind`'s service, no `fork`/`exec`. All authority arrives as handles from `tarwind`. | No ambient authority (Tarwin.md section 4.3) on top of XNU. |
| HS-009 | Images execute from `MAP_JIT` memory written once and sealed, after `tarwind` has verified the signature, train, CPU features and entitlements (Tarwin.md section 7.2). Tessera.app carries `com.apple.security.cs.allow-jit`. | The Tarwin trust store, not the macOS one, decides what Tessera code runs. |
| HS-010 | Threads are host threads. `tarwin-sched` keeps the class, deadline and donation state; the hosted layer applies it with pthread QoS classes, `thread_policy_set` and work intervals (`os_workgroup`). XNU does the dispatching. | XNU already does what TW-005 asks of the scheduler for interactive work; Tarwin keeps the accounting and the policy. |
| HS-011 | Storage is TRFS in `tarwind` over a file-backed block device: a sparse disk image in `~/Library/Application Support/Tessera/Disks/`, flushed with `F_FULLFSYNC`. A shared folder of the Mac's is a file-system server (Tarwin.md section 20.4) granted only through the picker. | TRFS is the file system; the Mac's disk is a block device, not a namespace. |
| HS-012 | Networking: Tarwin endpoints are backed by BSD sockets opened by `tarwind`, one per endpoint. Packet filtering and per-app rules run in `tarwind` before the socket call. No vmnet. | vmnet needs a restricted entitlement. Endpoint semantics are LibTessera's either way. |
| HS-013 | Graphics is Metal. The hosted GPU driver is a DeviceKit driver process that owns an `MTLDevice`; GPU buffers are `IOSurface`s, fences are `MTLSharedEvent`s exported as Tarwin fences (Tarwin.md section 22). Each MosaicDisplay output is a `CAMetalLayer` in a Tessera.app window. | Priam: Tarwin uses Metal drivers, not Ember. |
| HS-014 | Input, audio, power and sensors are hosted DeviceKit drivers fed by Tessera.app: `NSEvent` to HID, Core Audio to device streams, IOPowerSources to the power service. | Drivers stay in user space and restartable, as Tarwin requires. |
| HS-015 | Swift profiles follow Tarwin.md section 8.1: the gate stub and task-host entry are non-allocating Embedded Swift; the task host is Embedded Swift; `tarwind`, the hosted drivers and Tessera.app are regular Swift. | The task host shares an address space with untrusted app code and must not bring a hosted runtime into it. |
| HS-016 | Apple silicon only. x64 Macs are not offered. | Tarwin images for Tessera.app are aarch64 with 16 KiB pages, which match the host. |
| HS-017 | Hosted runs are extra evidence, never a substitute for the aarch64, x64 and rv64 results Tarwin.md section 1.4 requires. `BackendInfo.kind` stays Native; a new flag `HOSTED` reports the hosted kernel. | Do not weaken the hardware conformance bar. |

## 4. Architecture

```
Tessera.app (regular Swift, AppKit)
  windows with CAMetalLayer · NSEvent · Core Audio · menus, disks, start/stop
  launches and supervises tarwind
        │ XPC
tarwind (regular Swift)                         hosted DeviceKit drivers (tasks)
  Tarwin layers 1-5 unchanged                     metal-gpu · hid · audio · power
  tarwin-arch-hosted (layer 0)                    each a Tarwin task with device slots
  hosted block device · socket endpoints
        │ gate (mach_msg)    │ command port      │ shared memory
Task: one per Tessera process
  task host (Embedded Swift): check-in, sandbox, map, threads, gate stub
  the process's Tarwin images, LibTessera native backend unchanged
```

## 5. The task

### 5.1 Creation

1. `Process.create` in `tarwind` spawns `tarwin-task` (a Mach-O in Tessera.app) with `posix_spawn`, its bootstrap special port set to a fresh receive right in `tarwind`, an empty environment and no inherited descriptors.
2. The task host checks in on that port, keeping the receive right for its command port and sending `tarwind` a send right for it, plus the receive right for its gate port (the task keeps only send rights to the gate). `tarwind` records the pair against the Process object; the Process handle's signals follow the task's EVFILT_PROC events.
3. The task host applies the sandbox profile (HS-008), then waits for commands.
4. `tarwind` loads the process's images (section 5.3), creates the main thread with `Thread.start` and resumes it.

### 5.2 Commands

The command protocol is versioned, little-endian, one Mach message per command, answered with a status. Commands: map memory entry at address with protection, protect, unmap, create thread with entry, stack and TLS, set thread state for exception delivery, suspend and resume threads (Job.freeze), terminate. The task host validates nothing for security; it is not trusted. `tarwind` keeps the authoritative address-space map.

### 5.3 Loading

`tarwin-loader` runs in `tarwind` unchanged up to placement. The hosted layer then:

1. Places segments inside the task's Tarwin window (a fixed 64 GiB region reserved at task start, randomized per Tarwin.md section 13.9 within it).
2. Applies loader records, rewrites trap sites (HS-005), copies the result into a memory entry, sends map commands, and seals code (`MAP_JIT` written once, then read and execute only; data read-only after relocation).
3. Shares verified code pages between tasks through one memory entry per image per train, as section 7.2 requires; writable data is copy-on-write (`VM_INHERIT_COPY` entries).
4. Sets the thread-pointer register for static TLS. The TLS register MUST be checked on macOS 26 before freezing: if XNU does not preserve `TPIDR_EL0` for user threads, the loader rewrites TLS access sequences to read the TCB from the gate page instead.

### 5.4 Faults and exceptions

The task host installs a Mach exception port for its task pointing at `tarwind`. A fault in Tessera code becomes a Tarwin exception (section 11.4) on the faulting thread; demand paging of file-backed memory objects is done by `tarwind` mapping on the fault and resuming.

## 6. The gate

1. The stub (non-allocating Embedded Swift, one per image page set, never writable) saves the section 10.2 registers into a message, calls `mach_msg` with `MACH_SEND_MSG | MACH_RCV_MSG` on the gate port, and restores results.
2. `tarwind` receives on a port set over all gate ports with a pool of host threads sized to the Mac's cores. Each call runs the generated `TarwinSyscall` dispatch, the same code as on hardware.
3. User-memory copies (section 10.3) use `mach_vm_read_overwrite`-free access: argument blocks larger than the message are sent as out-of-line memory or read through the task's shared argument page, bounded per thread.
4. A call that blocks stores its reply right with the waiting thread's state and returns the worker; the wake path sends the reply.
5. Budget: one gate call within 3 microseconds round trip on an M-series Mac; `Time.read` and ring I/O never use the gate.

## 7. Memory

`tarwin-mm`'s pagers keep their objects; the hosted layer backs each Memory object with a memory entry: anonymous memory from `mach_make_memory_entry_64(MAP_MEM_NAMED_CREATE)`, purgeable with `VM_FLAGS_PURGABLE` and `vm_purgable_control`, file-backed objects filled by `tarwind` from TRFS on fault. Footprint is the sum of the task's charged entries; jetsam follows Tarwin.md section 13.10, with host memory pressure (`DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`) as the pressure signal. The compressor is XNU's; Tarwin's compressor is not used hosted. Memory tagging is not offered hosted (rule 5 of section 1.4: not offered rather than weakened).

## 8. Time

The time page is shared memory written by `tarwind` from `mach_continuous_time` and `mach_absolute_time` with the same layout as on hardware. Timers are kqueue `EVFILT_TIMER` with `NOTE_MACHTIME`; wake timers use IOPM scheduled wakes only when Tessera.app holds the user's permission.

## 9. Devices

Hosted DeviceKit drivers are Tarwin tasks with device slots that `tarwind` backs with host resources supplied by Tessera.app over XPC:

| Driver | Host resource | Tessera side |
| --- | --- | --- |
| `metal-gpu` | `MTLDevice`, `IOSurface`, `MTLSharedEvent` | GPU device objects, surfaces, fences, presentation deadlines from `CAMetalDisplayLink` |
| `mac-display` | One `CAMetalLayer` per output window; window size, scale and refresh as display modes | MosaicDisplay outputs |
| `mac-hid` | `NSEvent` keyboard, pointer, trackpad gestures, tablet | DeviceKit HID |
| `mac-audio` | Core Audio default input and output | Device streams (LibTessera.md section 16) |
| `mac-power` | IOPowerSources, thermal state | Power and thermal (section 26) |

## 10. Tessera.app

A regular Swift AppKit app in `apps/tessera-mac/`. It bundles `tarwind`, `tarwin-task`, the hosted drivers and a system image; creates the disk on first start; shows one window per display output with full-screen and resize; offers Start, Shut Down, Restart and Recovery; captures the keyboard while focused; and keeps `tarwind` as a child it restarts after a crash with the panic record shown. Signed with a development identity; hardened runtime with `allow-jit` only.

## 11. Build

`kira build` gets a `mac-hosted` target: aarch64 Tarwin images of the userland linked against LibTessera's native backend, packed into a TRFS system image, plus the macOS executables of sections 4 to 10 built with SwiftPM. `Ends when` checks run `tessera-mac-test`, which boots Tessera.app headless, waits for `tessera.init` to report ready and runs the hosted suites.

## 12. Work split

Each piece owns its paths; a change outside them goes through the owner. Interfaces in sections 5.2 and 6 are owned by H2 and frozen by its first landed request; H1 owns `docs/decisions.md` rows `HS-*`.

| Piece | Owns | Delivers | Needs first |
| --- | --- | --- | --- |
| H1 Hosted kernel | `tarwin/tarwin-arch-hosted/`, `tessera/build/tarwin-hosted/` (the `tarwind` composition), `tarwin/conformance/hosted/` | Layer 0 for macOS, `tarwind` linking layers 1-5, scheduling (HS-010), time (section 8), exceptions, hosted suite runs | none |
| H2 Task host and gate | `tarwin/tarwin-task/`, `tarwin/tarwin-syscall/hosted/`, `libtessera/app/Backend/Tarwin/hosted/` | Task creation, command protocol, sandbox, gate stub and dispatch, trap-site rewriting, TLS check | none; publishes the protocol first |
| H3 Hosted memory and loader | `tarwin/tarwin-mm/hosted/`, `tarwin/tarwin-loader/hosted/` | Memory entries, purgeable, file-backed faults, footprint and jetsam, image placement, sealing, shared code pages | H2 protocol |
| H4 Storage and network | `tarwin/tarwin-block/hosted/`, `tarwin/tarwin-net/hosted/`, `tarwin/trfs/` (hosted mount) | File-backed block device, TRFS disk, shared-folder server, socket endpoints and filtering | H1 |
| H5 Metal GPU and display | `tarwin/drivers/metal-gpu/`, `tarwin/drivers/mac-display/` | Metal driver, surfaces, fences, display outputs into Tessera.app windows | H1, H7 XPC |
| H6 Input, audio, power | `tarwin/drivers/mac-hid/`, `tarwin/drivers/mac-audio/`, `tarwin/drivers/mac-power/` | HID, audio streams, power and thermal | H1, H7 XPC |
| H7 Tessera.app and build | `apps/tessera-mac/`, `tessera/build/app/Hosted*.kira`, the `mac-hosted` build target | The app, XPC to `tarwind` and drivers, disk creation, system image, `tessera-mac-test` | H1 for a running kernel; can start immediately with a stub |

All seven can start the same day: H1, H2 and H7 have no inputs; H3 to H6 build against H2's protocol and H1's layer-0 interface, both published in their first request.
