# Tarwin Specification 1.0

Date: 2026-11-01. Tarwin version: 26.11.1. Status: normative draft 1.0. Audience: every agent and engineer who implements the Tarwin kernel, its boot loader, its reference virtual machine monitor, the kernel side of DeviceKit, or LibTessera's native backend.

Contents

1. Status, scope and rules for implementers
2. Terminology
3. Goals, non-goals and related work
4. Architecture
5. Hardware requirements
6. Boot
7. Images and the loader
8. The Kira kernel profile
9. Objects, handles and rights
10. System calls
11. Processes, jobs and threads
12. Scheduling
13. Virtual memory
14. Kernel memory allocation
15. Synchronization
16. Inter-process communication
17. Time and timers
18. Interrupts, exceptions and traps
19. Device access and the kernel side of DeviceKit
20. Storage
21. Networking
22. GPU and accelerator support
23. The hypervisor
24. The reference virtual machine monitor
25. Security
26. Power and thermal management
27. Probes: verified kernel extensions
28. Observability and debugging
29. Updates and soft reboot
30. Panics, watchdogs and recovery
31. LibTessera on Tarwin
32. Limits
33. Versioning
34. Conformance and performance
35. Diagnostics
36. Implementation plan
37. Appendix A: layouts
38. Appendix B: decision log

---

## 1. Status, scope and rules for implementers

This document is the single normative specification of Tarwin, Tessera's kernel. It defines the hardware Tarwin requires, how it boots, how it loads images, the kernel object model, system calls, processes, scheduling, virtual memory, kernel allocation, synchronization, IPC, time, interrupts and exceptions, device access for user-space drivers, the in-kernel storage and network stacks, GPU support, the hypervisor and the reference virtual machine monitor, security, power, verified kernel extensions, observability, updates, recovery, and LibTessera's native backend. An implementation that satisfies every MUST in this document is a conforming implementation of Tarwin version 26.11.1.

### 1.1 Normative language

- MUST, MUST NOT, SHOULD, SHOULD NOT and MAY carry their RFC 2119 meanings.
- Sections or paragraphs titled "Rationale" or "Example" are informative. Everything else is normative.
- Where prose and a table disagree, the table wins. Where a layout in Appendix A and prose disagree, the layout wins.

### 1.2 Relationship to other documents

| Document | Relationship |
| --- | --- |
| `LibTessera.md` | The system interface. Tarwin implements every LibTessera object and call natively (section 31). LibTessera is the only code that issues Tarwin system calls |
| `TIR.md` | The kernel profile (TIR.md section 31.1) under which Tarwin is compiled; the device runtime whose loader Tarwin hosts (section 7) |
| `TVISA.md` | The native image contents, thread control block, trap-site tables and hardening sequences Tarwin relies on and enforces |
| `DeviceKit.md` | The driver model. Tarwin provides the kernel mechanisms drivers use (section 19); DeviceKit defines the driver API, matching and lifecycle |
| `TRFS.md` | The file system, which runs in the kernel (section 20) |
| `Ember.md` | The GPU API, whose driver contract relies on section 22 |
| `MosaicDisplay.md` | The compositor, which owns display configuration |

### 1.3 Scope

Tarwin is the kernel only. It contains no user interface, no policy that belongs to system services (launching, grants, presence, notifications), no device drivers beyond the boot-critical set of section 4.2, and no compatibility layer for other operating systems' interfaces.

### 1.4 Rules for implementing agents

1. Implement behavior exactly as written. Where the document is silent, choose the behavior that is safest first and fastest second, and record the choice in `docs/decisions.md` in the format of Appendix B.
2. Tarwin is written entirely in Kira, compiled through TIR's kernel profile. Assembly appears only in `[privileged]` assembly inside variant bodies under the all-three rule (TIR.md section 20.3). No other language is used.
3. No placeholder, stub or hardcoded success counts as an implementation. A section is implemented when its conformance tests (section 34) pass on aarch64, x64 and rv64.
4. Every kernel subsystem has a performance budget (section 34.2). A change that regresses a budget is not merged.
5. No compromise: a feature that cannot meet this document's security and isolation rules on some hardware is not offered on that hardware, rather than offered weakened.

---

## 2. Terminology

| Term | Meaning |
| --- | --- |
| Object | A kernel entity reachable from user space through handles |
| Handle | A process-local 64-bit name for an object with a set of rights |
| Rights | What a handle permits (LibTessera.md section 3.3) |
| Job | A tree node that owns processes and child jobs and carries limits |
| QoS class | A scheduling class expressing the user-visible importance of work |
| Scheduling context | The QoS class, relative priority, deadline parameters and accounting a thread runs with; donated across synchronous IPC |
| Memory object | A pageable or physical memory object that can be mapped (LibTessera `Memory`) |
| Pager | The kernel component that supplies a memory object's pages (anonymous, file, compressed, physical) |
| Boot set | The signed bundle `tarboot` loads: kernel, early system processes, boot-device drivers, configuration |
| System image | The immutable TRFS snapshot that holds the operating system |
| Boot-critical driver | One of the few drivers inside the kernel (section 4.2) |
| Ring | A shared-memory single-producer, single-consumer queue between the kernel and a process (Appendix A.4) |
| Probe | A verified, bounded TIR program attached to a kernel hook (section 27) |
| VMM | A virtual machine monitor: a user-space process that runs virtual machines through the hypervisor API |

---

## 3. Goals, non-goals and related work

### 3.1 Goals

1. Performance within 5% of Linux on the benchmarks of section 34.2, measured on the same hardware, with better tail latency for interactive and real-time work.
2. Security without exceptions: capability-only authority, mandatory hardware security features, code signing of every executable page, isolation of drivers behind the IOMMU, measured and verified boot.
3. A modern hybrid design: the performance-critical subsystems (scheduling, memory, IPC, file system, network stack) are in the kernel; device drivers are restartable user-space processes.
4. Completion-based I/O everywhere, with shared rings so that steady-state I/O needs no system calls.
5. One kernel for phones, tablets, laptops, desktops, consoles, servers and virtual machines, on aarch64, x64 and rv64.
6. Memory safety by construction: Kira's ownership model, TIR's verification, and hardware tagging where present.

### 3.2 Non-goals

- POSIX, Linux system-call compatibility, or any other operating system's interface. Other operating systems run as virtual machines (section 24).
- Loadable kernel modules. Kernel extension is by probes only (section 27).
- Support for hardware below section 5's requirements.

### 3.3 Related work (informative)

| System | What Tarwin shares | Where Tarwin differs |
| --- | --- | --- |
| XNU | Hybrid design, QoS scheduling, compressed memory, jetsam, code signing, pointer authentication | User-space drivers; capability handles instead of Mach ports and BSD identities; written in Kira |
| Zircon (Fuchsia) | Objects, handles and rights, ports, jobs, no ambient authority | File system and network stack in the kernel for performance |
| seL4 and L4 | Fast synchronous IPC with scheduling-context donation | Not a microkernel; no formal proof requirement in 1.0 |
| Linux | EEVDF, io_uring-style rings, eBPF-style verified extensions, KVM-style hypervisor | No POSIX; capability security; drivers in user space |
| Windows NT | Completion ports, hybrid design | Capability-only security, open source |

---

## 4. Architecture

### 4.1 Overview

```
User space
  applications and frameworks ─ LibTessera ──────────────────┐
  system services (Launcher, Namespace, Presence, logger, …)  │ system calls, rings
  DeviceKit manager and drivers (storage, network, GPU, …)    │
  compile service, VMMs                                        │
───────────────────────────────────────────────────────────────┼────────────────────
Tarwin                                                         ▼
  objects and handles · IPC (channels, ports, synchronous calls) · system-call layer
  scheduler · virtual memory, pagers, compressor · kernel allocator · time
  image loader · code-signing enforcement · entitlement checks
  TRFS and the block layer · network stack · crypto engine
  device access (MMIO, interrupts, DMA, IOMMU) · GPU memory and fences
  hypervisor · probes · tracing · power and thermal
  boot-critical drivers: interrupt controllers, timers, IOMMUs, early console, PSCI/SBI/ACPI glue
───────────────────────────────────────────────────────────────────────────────────
Hardware and firmware
```

### 4.2 What is in the kernel

| In the kernel | In user space |
| --- | --- |
| Object model, handles, rights, IPC | System services (LibTessera.md sections 12 to 14) |
| Scheduler, virtual memory, kernel allocator, time | Every device driver: storage controllers, network interfaces, GPUs, NPUs, display, audio, input, USB, Wi-Fi, Bluetooth, cellular, sensors, cameras |
| Image loader, code signing, entitlement checks | The compile service and its JIT and finalizer |
| TRFS, the block layer, encryption | DeviceKit's manager (matching, power policy, restart) |
| Network stack (IPv6, IPv4, TCP, UDP, ICMP), packet filtering | DNS resolution, TLS, QUIC, VPN protocols, Wi-Fi management |
| GPU memory objects and fences | GPU command encoding (Ember's family layers) and GPU scheduling firmware interfaces (the GPU driver) |
| Hypervisor | VMMs (section 24) |
| Boot-critical drivers: interrupt controllers (GICv3/v4, x2APIC and IOAPIC, AIA), architectural timers, IOMMUs (SMMUv3, VT-d, AMD-Vi, RISC-V IOMMU), the TPM 2.0 interfaces (CRB, TIS, firmware TPMs) and the SoC secure element's mailbox, the platform watchdog, early console (UART or firmware framebuffer, debug images only), firmware interfaces (PSCI, SBI, ACPI tables, UEFI runtime services, device tree) | Everything else |

### 4.3 Trust boundaries

1. The kernel trusts no user-space process, including drivers. A driver can only reach the device it was given, through handles, and its DMA is confined by the IOMMU.
2. Services that hold system authority (Launcher, Namespace, Presence, DeviceKit manager, compile service) receive it as handles to privileged resources (section 9.4), never by identity.
3. The kernel trusts firmware only as measured by verified boot (section 25.6).

---

## 5. Hardware requirements

### 5.1 CPUs

| Architecture | Mandatory | Used when present |
| --- | --- | --- |
| aarch64 | The `aarch64.base` target of TVISA.md section 30.2; EL2 with FEAT_VHE; FEAT_PAN and PAN2; FEAT_TGran16 (16 KiB translation granule); GICv3; generic timer; PSCI 1.1 | FEAT_MTE2 and MTE3, FEAT_GCS, FEAT_FPAC, FEAT_EPAN, GICv4.1, FEAT_LPA2, FEAT_NV2 (nested virtualization), FEAT_RME (Arm CCA), SVE2, SME2 |
| x64 | The `x64.v3` target of TVISA.md section 30.2, including CET shadow stacks and indirect branch tracking in user and supervisor mode; SMEP, SMAP, UMIP; x2APIC; invariant TSC with TSC-deadline mode; VMX with EPT, unrestricted guest and posted interrupts, or SVM with NPT and AVIC | LA57, AVX-512 and AVX10, AMX, APX, PKS, LASS, FRED, TDX or SEV-SNP |
| rv64 | The `rv64.base` target of TVISA.md section 30.2; the RVA23S64 supervisor profile (including the H extension, Sstc, Svpbmt, Svinval, Svnapot, Sv48); Zicfiss and Zicfilp in supervisor mode; AIA (Ssaia, IMSIC, APLIC); SBI 2.0 | Sv57, Smmtt and confidential-computing extensions, later profile extensions |

A system whose CPUs do not all meet the mandatory column is not supported. Heterogeneous systems (performance and efficiency cores) are supported; features count as present only if every core has them, except where section 12.8 allows otherwise.

### 5.2 Platform

| Component | Requirement |
| --- | --- |
| Firmware | UEFI 2.9 or later with Secure Boot (laptops, desktops, servers, virtual machines, rv64 platforms with UEFI); or a SoC boot chain with verified boot that loads `tarboot` as a signed payload and supplies a device tree (phones, tablets) |
| Tables | ACPI 6.4 or later on UEFI systems; device tree (specification 0.4 or later) otherwise |
| IOMMU | Mandatory, covering every DMA-capable device: SMMUv3, Intel VT-d 3.0 or later (scalable mode), AMD-Vi with v2 page tables, or the RISC-V IOMMU. A device not behind an IOMMU is never given to a driver |
| Root of trust | TPM 2.0 (discrete, firmware or integrated, such as Pluton), or a SoC secure element implementing DICE, with monotonic counters and sealed storage |
| Memory | At least 8 GiB on phones and tablets, 16 GiB on other devices |
| Storage | NVMe 1.4 or later, or UFS 4.0 or later, with at least 256 GB |
| Random | A hardware entropy source (FEAT_RNG, RDSEED, Zkr, the TPM, or a SoC TRNG) |

### 5.3 Device classes

Device tiers (High End, Mid End, Low End) are Tessera policy reviewed yearly; Tarwin exposes the hardware facts that policy reads (`System.info`). Any supported device can run Tarwin; tiers affect only what software the device is offered.

---

## 6. Boot

### 6.1 Chain

```
firmware (UEFI Secure Boot, or SoC verified boot)
  └─ tarboot (signed UEFI application or SoC payload)
       ├─ verifies and measures the boot set and boot configuration
       └─ hands off to the Tarwin kernel with the boot information block
            ├─ boot-critical drivers, memory, scheduler
            ├─ starts the early processes from the boot set (init, DeviceKit manager, boot-device drivers)
            ├─ mounts the system image (TRFS) through the boot-device driver
            └─ init starts the system services from the system image
```

### 6.2 tarboot

1. `tarboot` is Tarwin's boot loader, written in Kira under the kernel profile, built for each architecture as a PE32+ UEFI application and as a raw payload for SoC boot chains.
2. It reads the boot configuration, selects a slot (section 6.5), loads the slot's boot set into memory, verifies its signature against the platform key chain (section 25.5), measures it (section 6.4), applies kernel address randomization (section 7.6), exits boot services, and jumps to the kernel entry with the boot information block.
3. It offers recovery when a key combination, a failed-boot counter or a recovery request selects it; it never offers a shell.

### 6.3 Boot set

A boot set is one signed archive (the TIR archive container, TIR.md section 29.6) holding: the kernel image for the CPU target; the boot configuration (canonical JSON: slot, flags, kernel options allowed by the image's signature); the early processes `tessera.init`, `devicekit.manager`, the boot-device storage drivers and the compile-service-free subset of LibTessera they need; the device-tree overlays for the platform, if any; and the hashes of the system image snapshot it expects. Everything in it is native code for the device's CPU target; nothing in a boot set is finalized on the device.

### 6.4 Measured boot

1. `tarboot` extends the TPM's PCR 8 with the boot set's hash and PCR 9 with the boot configuration's, and records events in the TCG event log format; on DICE platforms it derives the next compound device identifier from the same measurements.
2. The kernel extends PCR 10 with each early process's image hash before running it, and PCR 11 with the system image snapshot's root hash before mounting it.
3. Soft reboots (section 29.3) extend PCR 12 with the new boot set's hash, so the measurement log always describes the running software.

### 6.5 Slots, counters and rollback

1. The system has two slots, A and B, each with a boot set and a system image snapshot. The boot configuration in a protected firmware variable (or the SoC's equivalent) names the active slot, a tries-remaining counter (initially 3) and a success flag.
2. `tarboot` decrements the counter before booting an unconfirmed slot; `tessera.init` sets the success flag once the system services are up. A slot whose counter reaches zero is abandoned and the other slot is booted.
3. Anti-rollback: each boot set carries a security version. `tarboot` refuses a boot set whose version is below the monotonic counter held in the TPM's NV storage or the secure element, and raises the counter after a confirmed boot.
4. A recovery boot set lives in its own partition, signed with the same chain, and can reinstall both slots.

### 6.6 Kernel entry state

| Architecture | State at entry |
| --- | --- |
| aarch64 | EL2, MMU off, data and instruction caches clean to the point of coherency for the loaded images, interrupts masked, `x0` = physical address of the boot information block, all other CPUs held by PSCI |
| x64 | 64-bit long mode, paging on with an identity map of the loaded images and the boot information block, interrupts disabled, `rdi` = physical address of the boot information block, application processors not started |
| rv64 | S-mode (HS-mode with H), `satp` = 0, interrupts disabled, `a0` = hart identifier, `a1` = physical address of the boot information block, other harts stopped through SBI HSM |

The boot information block is Appendix A.1. It carries the memory map, the firmware tables (RSDP or device tree), the UEFI runtime services table, the framebuffer description (for the early console on debug images and the boot splash), the boot set's location and size, a 64-byte entropy seed from the platform source, the TCG event log, the slot, the security state (Secure Boot enabled, debug image, developer mode), and the randomized kernel base.

### 6.7 Bringing up CPUs

Secondary CPUs start through PSCI `CPU_ON` (aarch64), INIT-SIPI-SIPI or the ACPI multiprocessor wakeup mailbox (x64), or SBI HSM `hart_start` (rv64). Each CPU enables its security features (PAN, BTI, PAC keys, CET, Zicfiss and Zicfilp, SMEP, SMAP, UMIP) before it runs any other kernel code.

---

## 7. Images and the loader

### 7.1 Format

Tarwin images are ELF64 files under the Tessera profile:

1. Type `ET_DYN`, little-endian, machine `EM_AARCH64`, `EM_X86_64` or `EM_RISCV`.
2. `PT_LOAD` segments aligned to the architecture's page size (16 KiB on aarch64, 4 KiB on x64 and rv64), never both writable and executable; `PT_GNU_RELRO` covers relocated read-only data; `PT_TLS` holds the TLS template; `PT_NOTE` holds the Tessera notes.
3. No `PT_INTERP` and no `PT_DYNAMIC`: the kernel is the loader, and its inputs are the loader records of section 7.3.
4. The sections are those of TVISA.md section 18.2.

Tessera notes (`PT_NOTE`, owner `Tessera`):

| Type | Content |
| --- | --- |
| 1 | Build identifier (BLAKE3-256 of the image without its signature) |
| 2 | Signature (hybrid Ed25519 and ML-DSA-65 over the build identifier, the train, the CPU target and the entitlements) and the signer's certificate chain |
| 3 | Entitlements (canonical JSON) |
| 4 | Train, TIR version, expiry train |
| 5 | CPU target, feature set, `svec` mode (TVISA.md section 15.2) |
| 6 | For finalized images, the TVISA image hash and the finalizer build (TVISA.md section 20.3) |
| 7 | Profile (`app`, `system`, `driver`, `kernel`) and image kind |

### 7.2 Loading

The loader is part of the kernel. To load an image into a process, it:

1. Verifies the signature against the trust store for the image's profile (section 25.5); checks expiry (`TIR-RT-0400`), train (`TIR-RT-0402`) and signature validity (`TIR-RT-0401`).
2. Checks the CPU target's features against the CPU (`TVISA-RT-0004`) and the `svec` mode against the process (`TVISA-RT-0002`).
3. Maps segments with randomized placement (section 13.9), applies the loader records, binds imports eagerly against the images already loaded or the frameworks it loads in turn (RIDL link check, `TIR-RT-0200`), fills runtime and dispatch slots and the feature table, signs code pointers in storage form with the process's keys (aarch64), lays out static TLS (TVISA.md section 19.2), and then makes relocated data read-only.
4. Registers the image's trap-site table and unwind tables with the process, so traps and faults are reported per TVISA.md section 17.10.
5. Runs initializers in priority order on the process's main thread when the process starts, or on the loading thread for images loaded later.

Images are shared between processes: the kernel caches verified, relocated-read-only-ready images per train and maps the same physical pages of code and read-only data into every process that loads them. Per-process data (writable data, relocated data, slots) is copy-on-write.

### 7.3 Loader records

The `.tirload` section holds, in order:

| Record table | Encoding |
| --- | --- |
| Relative relocations | A RELR-style bitmap encoding of 8-byte slots that receive the image base added to their contents |
| Authenticated relative relocations | Per slot: image offset, `u32` type tag (TVISA.md section 17.2); on aarch64 the loader signs the rebased value in storage form |
| Imports | Per import: module path, symbol, ABI UUID, kind, tag, slot offset |
| Runtime entries | Per used entry identifier: slot offset |
| Dispatch sets | Per set: slot offset, candidate members with their features in preference order |
| Thread-local offsets | Per slot: offset of a TLS symbol to resolve to a thread-pointer offset |
| GPU entries | The `.tirgpu` entry count, for registration with `libtirrt` |
| Feature table | Per byte: the feature name it reports |

### 7.4 Executable memory

Only the loader, the hypervisor (for guest memory, which is never executable by the host) and memory objects sealed by the compile service (TIR.md section 28.2) produce executable mappings in user processes. A process can never make writable memory executable or executable memory writable (section 25.3).

### 7.5 The kernel image

The kernel is an image of profile `kernel`, linked for Tarwin's kernel code model: position independent, mapped in the upper half of the address space (TTBR1 on aarch64, the top half on x64 and rv64), with no relocations other than relative relocations applied by `tarboot`.

### 7.6 Kernel address randomization

`tarboot` chooses the kernel's virtual base uniformly among 2^18 aligned positions in the kernel's region and its physical placement randomly among suitable memory, from the platform entropy source. The direct map, the allocator's regions and the per-CPU areas are randomized separately at startup.

---

## 8. The Kira kernel profile

### 8.1 Language

Tarwin's code is Kira compiled under TIR's kernel profile (TIR.md section 31.1) with these rules:

1. `unsafe` blocks are the only place where raw pointers are dereferenced, MMIO is accessed, privileged assembly is called, or page tables are edited. Every `unsafe` block carries a comment stating the invariant it relies on; review rejects one without it.
2. Floating-point and vector types appear only in functions marked `@KernelFloatingPoint` (TIR's `kernel.fp`), which bracket their use with the scheduler's lazy state save (section 12.10). Everything else is compiled with `no_fp_regs`.
3. Every function declares its context: `@AnyContext` (callable with interrupts disabled and while holding spinlocks), `@Sleepable` (may block). The default is `@Sleepable`. The compiler checks that `@AnyContext` code calls only `@AnyContext` code and never allocates with sleeping allocation flags (`TARWIN-K0001`).
4. No unwinding: every kernel function is `nounwind`. Recoverable errors are `Result` values; unrecoverable ones panic (section 30).
5. Recursion is allowed only where a static bound on depth is stated and checked by the stack analysis (section 8.3).

### 8.2 The kernel standard library

The kernel's `std` replacement, `kcore`, provides collections that never allocate implicitly (callers pass allocation contexts), intrusive lists and trees, lock types (section 15), atomic types, per-CPU variables, bit manipulation, checked arithmetic, and the kernel allocator interface (section 14). Kira's general `std` is not linked into the kernel.

### 8.3 Stacks

Each thread has a kernel stack of 32 KiB on aarch64 (two 16 KiB pages) and 24 KiB on x64 and rv64, with a guard page below and a shadow stack (x64 CET supervisor shadow stack, aarch64 GCS when present, rv64 Zicfiss) beside it. Interrupts and exceptions run on per-CPU stacks of the same size. The build computes the maximum stack depth of every path from the call graph and fails if any exceeds 80% of its stack (`TARWIN-K0002`).

### 8.4 Per-CPU data

Per-CPU variables are globals with the `percpu` flag (TIR.md section 31.1). The per-CPU base is `TPIDR_EL1` on aarch64, `GS` base on x64, and on rv64 the `sscratch`-addressed per-CPU block whose address the kernel loads into `tp` on kernel entry (user `tp` is saved in the thread's trap frame).

---

## 9. Objects, handles and rights

### 9.1 Objects

Every kernel object has a header holding its type, a kernel object identifier (`koid`: 64-bit, unique for the boot, never reused), a reference count (handles plus kernel references), its signal state and observers, its owning job (for accounting), and its maximum rights. Objects are destroyed when the last reference goes; destruction cancels in-flight operations, which complete with `Cancelled` (LibTessera.md section 3.5).

### 9.2 Object types

Tarwin implements LibTessera's object types 0 to 18 (LibTessera.md section 3.2) and adds:

| Code | Type | Purpose | Section |
| --- | --- | --- | --- |
| 19 | `Interrupt` | A device interrupt delivered to a driver | 19 |
| 20 | `MmioRange` | A range of device registers | 19 |
| 21 | `DmaBuffer` | Pinned memory mapped into a device's IOMMU domain | 19 |
| 22 | `IommuDomain` | A device's DMA address space | 19 |
| 23 | `DeviceSlot` | One device (a PCIe function or a platform device) with its resources, granted to one driver | 19 |
| 24 | `VirtualMachine` | A guest physical address space and its devices | 23 |
| 25 | `VirtualCpu` | A guest CPU | 23 |
| 26 | `Probe` | An attached verified kernel extension | 27 |
| 27 | `Resource` | A privileged authority (section 9.4) | 9 |
| 28 | `Service` | The server side of synchronous calls on a channel | 16 |
| 29 | `Ring` | A shared-memory ring pair between the kernel and a process | 10, 19 |
| 30 | `WorkInterval` | A group of threads working to periodic deadlines | 12 |
| 31 | `PerformanceSession` | Access to CPU performance counters | 28 |

### 9.3 Handle tables

1. Each process has one handle table. A handle value is `(salt << 56) | (generation << 20) | index`, where `index` (20 bits) selects the entry, `generation` (36 bits) increments each time the entry is reused, and `salt` (8 bits) is chosen randomly when the process is created. 0 is never valid.
2. Each entry holds the object reference and the handle's rights. Every system call checks the handle's type and rights before acting (`AccessDenied`, `WrongType`, `InvalidHandle`).
3. The default limit is 65,536 handles per process; a job's policy may raise it to 1,048,576.
4. Handle operations are lock-free for lookups (the table is read under epoch protection, section 15.1) and take a per-table lock for insertion and removal.

### 9.4 Resources

Privileged operations require a `Resource` handle of the right kind. Resources are created by the kernel at boot and given to `tessera.init`, which passes each to the one service that needs it. They never reach applications.

| Kind | Authority | Held by |
| --- | --- | --- |
| `Launch` | Create processes with identity, entitlements and a sandbox; create top-level jobs | Launcher service |
| `DeviceRoot` | Enumerate hardware, create `DeviceSlot`s and grant them to drivers | DeviceKit manager |
| `Namespace` | Mount file systems and mint `Node` handles for any path | Namespace service |
| `Power` | System sleep, reboot, shutdown, CPU and device power policy | Power service |
| `Clock` | Set UTC time | Time service |
| `Debug` | Attach to processes, read their memory, receive their exceptions | Debug service (developer mode and debug images) |
| `Probe` | Attach probes | Trace service and developer tools |
| `Security` | Key management, attestation quotes, sealed storage | Security service |
| `Network` | Interface configuration, routing, per-application network policy, packet-filter attachment | Network service |
| `Hypervisor` | Create virtual machines for system purposes beyond the entitlement of section 23.1 | Virtualization service |

### 9.5 Entitlements

The kernel enforces entitlements carried in each image's signed entitlement note (section 7.1) at the system calls that create or use the governed objects: dynamic code (`tessera.tir.dynamic`), network endpoints (`tessera.network.client`, `tessera.network.server`), virtualization (`tessera.hypervisor`), real-time scheduling (`tessera.scheduling.realtime`), and the Ember entitlements (Ember.md section 32), among the complete list in section 25.4. A process's entitlements are the intersection of its executable's and its job's ceiling.

### 9.6 Signals and waiting

Objects assert the signals of LibTessera.md section 3.4. `Object.wait` blocks a thread; `Object.waitAsync` arms a one-shot or repeating observer that posts a `Signal` completion to a port. Observers are kept in the object, and a signal change wakes them in order of arming.

---

## 10. System calls

### 10.1 Who may call

Only LibTessera issues system calls. The loader records the address range of LibTessera's code in each process. A system-call instruction executed outside that range terminates the process with `TARWIN-S0001`. The system-call interface is private: it may change with every train, because LibTessera and the kernel ship together.

### 10.2 Entry

| Architecture | Instruction | Call number | Arguments | Results |
| --- | --- | --- | --- | --- |
| aarch64 | `svc #0` | `x16` | `x0`–`x7` | `x0` status, `x1` detail, `x2`–`x3` values |
| x64 | `syscall` | `rax` | `rdi`, `rsi`, `rdx`, `r10`, `r8`, `r9` | `rax` status, `rdx` detail, `rsi`, `rdi` values |
| rv64 | `ecall` | `a7` | `a0`–`a6` | `a0` status, `a1` detail, `a2`–`a3` values |

1. Status is LibTessera's `Error` code and subsystem packed as `code | (subsystem << 32)`, zero on success; detail is its 64-bit detail word.
2. Calls with more arguments than registers pass a pointer to an argument block in user memory.
3. Every register not used for results is preserved, including floating-point and vector registers (x64 `syscall` clobbers `rcx` and `r11`, which LibTessera's stubs account for).
4. Call numbers are assigned per train by sorting LibTessera's call index (LibTessera.md section 23); the table is generated into both LibTessera and the kernel by the build.

### 10.3 Access to user memory

The kernel reads and writes user memory only through copy routines that use unprivileged loads and stores (`ldtr`/`sttr` on aarch64; on x64 and rv64, accesses bracketed by `stac`/`clac` or `sstatus.SUM` with the user range checked first), so user permissions and memory tags are checked as if user code made the access. A fault in a copy routine returns `InvalidArgument` to the caller.

### 10.4 Paths that need no system call

| Path | Mechanism |
| --- | --- |
| Time | A read-only kernel time page mapped into every process: clock parameters, update sequence counter, UTC offset |
| Asynchronous operations | Submission and completion rings of ports (section 10.5) |
| Uncontended synchronization | `Sync.wait32`/`wake` only enter the kernel when a thread must sleep or be woken |
| GPU submission | User-mode queues (Ember.md section 29.4) |
| Driver I/O | Rings and doorbells (section 19.6) |

### 10.5 Port rings

1. A port may be created with rings: a submission ring of 64-byte operation records and a completion ring of 64-byte `Completion` records (LibTessera.md section 5.2), in a Memory object shared between the process and the kernel.
2. LibTessera writes operations (I/O, timers, waits, channel operations) to the submission ring. The kernel consumes them when a thread calls `Port.enter`, which also waits for completions, or continuously when the port belongs to a process with a dedicated polling CPU (system services only, through the `Power` resource's policy).
3. Completions are written to the completion ring in completion order per object. `Port.wait` reads the ring and enters the kernel only to sleep.
4. Ring sizes are powers of two from 64 to 65,536 entries. A full completion ring holds completions in the kernel (bounded by the port's capacity) until space is available; nothing is lost.

---

## 11. Processes, jobs and threads

### 11.1 Jobs

Jobs form a tree rooted at the kernel's root job. A job's policy, inherited as a ceiling by its children:

| Policy | Meaning |
| --- | --- |
| Memory limit | Maximum footprint (section 13.13) of all processes beneath |
| Jetsam band | The memory-pressure band of its processes (section 13.10) |
| QoS ceiling | The highest QoS class its threads may use |
| CPU limit | Maximum share of CPU time over a window |
| I/O ceiling | The highest I/O priority |
| Limits | Maximum processes, threads per process, handles per process |
| Entitlement ceiling | Entitlements its processes may hold |
| Kill on close | Kill every process when the last job handle closes |

`Job.freeze` stops every thread of the job at its next return to user space and keeps it stopped until `Job.thaw`; frozen processes use no CPU and are first in line for memory reclamation. MosaicShell uses it when switching Dynamic Platforms, and the app lifecycle uses it to suspend background apps.

### 11.2 Creating processes

There is no `fork`. The Launcher service creates processes with its `Launch` resource:

1. The kernel creates the address space, the handle table and the main thread (suspended); records the identity (application identifier, process identifier, developer team, code-signing source, developer mode) and the entitlements; loads the executable and its dependencies (section 7.2); sets the process's pointer-authentication keys, memory-tagging mode, `vscale`, shadow-stack configuration and system-call range; and installs the startup handles the Launcher lists, including the child's bootstrap channel.
2. The Launcher returns a `Process` handle and a private channel to the parent (LibTessera.md section 11.1).
3. Each process has fresh random pointer-authentication keys (aarch64: IA, IB, DA, DB, GA), shared by its threads.

### 11.3 Threads

1. Threads are created suspended by `Thread.create` with an entry, an argument, a stack (a LibTessera Memory mapping with a guard region of at least 64 KiB below it), and a thread control block address (TVISA.md section 19); `Thread.start` runs them.
2. The kernel allocates each thread's user shadow stack (x64 CET, aarch64 GCS, rv64 Zicfiss) of one eighth of its stack size, at least 16 KiB, with guard pages, and its kernel stack (section 8.3).
3. Floating-point and vector state is saved eagerly at every switch. SVE, SME and AMX state is saved only for threads that have used it; first use traps once to enable it (on x64 through XFD).
4. The thread pointer register is set to the TCB address at creation and preserved per thread.

### 11.4 Exceptions

1. Synchronous faults (page faults with no mapping, permission faults, alignment faults, undefined instructions, breakpoints, traps listed in `.tirtrap`, pointer-authentication and control-flow faults, tag-check faults, shadow-stack faults) are delivered as exception messages to the thread's exception channel, then the process's, then each ancestor job's, then the system crash handler, until one resumes or terminates the thread.
2. Each message carries the TIR runtime code when the fault maps to one (`TIR-RT-0012` for forward-edge integrity, `TIR-RT-0013` for return-address integrity, `TIR-RT-0014` for the stack protector, `TIR-RT-0021` for stack overflow detected at a guard region, `TIR-RT-0032` for tag-check faults, and the code in the trap-site table for TIR traps), the faulting address, the registers, and a backtrace from frame pointers.
3. When nothing handles an exception, the process terminates and the crash handler records a crash report (section 28.4).
4. There are no signals.

### 11.5 Termination

A process terminates when its last thread exits, when it calls `Process.exit`, when it is killed through a `Process` or `Job` handle with `Manage`, or by jetsam. Its handles are closed, its memory released, its observers notified with `TERMINATED`, and its job's accounting updated.

---

## 12. Scheduling

### 12.1 Classes

| Class | Use | Policy |
| --- | --- | --- |
| `Deadline` | Audio, display composition, input, real-time media | Earliest deadline first with a constant-bandwidth budget per thread (section 12.3) |
| `UserInteractive` | Work that produces the next frame or responds to input | EEVDF, highest weight |
| `UserInitiated` | Work the user is waiting for | EEVDF |
| `Default` | Unclassified work | EEVDF |
| `Utility` | Long work the user is aware of (downloads, imports) | EEVDF, efficiency-core preference |
| `Background` | Work the user does not see (indexing, backups, prefetch) | EEVDF, efficiency cores only, throttled under thermal pressure |
| `Idle` | Per-CPU idle loop | |

### 12.2 Precedence and fairness

1. On each CPU, a runnable thread of a higher class runs before any of a lower class, except that a lower-class thread waiting longer than its starvation bound receives one quantum: 100 ms for `Default`, 250 ms for `Utility`, 1 s for `Background`.
2. Within a QoS class, threads are scheduled by EEVDF (earliest eligible virtual deadline first). A thread's relative priority, −16 to +15, sets its weight; its requested slice (1 to 20 ms, default 3 ms) sets its virtual deadline.
3. QoS is propagated: a thread waiting on work done by another (through IPC, a mutex with priority inheritance, a wait-on-address with an owner, or a port completion it is waiting for) raises that work to its own class until the wait ends.

### 12.3 Deadline class

1. A deadline thread declares a budget (runtime), a period and a relative deadline. The kernel admits it only if the total utilization of admitted deadline threads on its CPU cluster stays at or below 90% (`InsufficientResources` otherwise).
2. Admitted threads are scheduled earliest-deadline-first ahead of every QoS class, each consuming at most its budget per period; a thread that exhausts its budget runs as `UserInteractive` until its next period.
3. Deadline scheduling requires the entitlement `tessera.scheduling.realtime`, held by system services and by applications that perform real-time audio or communication; a job's policy can cap the total budget its processes may reserve.

### 12.4 Work intervals

A `WorkInterval` groups the threads that produce something periodic, typically a frame. The owner declares each interval's start and deadline and marks its completion. The scheduler uses the history of intervals to choose cores and frequencies that meet the deadline with the least energy, and boosts the group when an interval is about to miss. KiraUI, KCoreAnimation, Ember presentation in low-latency mode and the audio service use work intervals.

### 12.5 Scheduling contexts and donation

A thread's scheduling context (class, relative priority, deadline parameters, budget accounting) can be donated: a synchronous IPC call (section 16.4) runs the server thread on the caller's context until it replies, so a server serving an interactive client runs at the client's class and is charged to the client.

### 12.6 Placement

1. The kernel builds a capacity and energy model of every CPU from ACPI CPPC and processor tables, or the device tree's capacity and energy-model properties.
2. `Deadline`, `UserInteractive` and `UserInitiated` threads are placed on the CPU that meets their demand at the lowest energy, including performance cores. `Utility` threads prefer efficiency cores and use performance cores only when those are idle and thermal headroom exists. `Background` threads run only on efficiency cores, on systems that have them.
3. A thread runs only on CPUs that have every ISA feature its process's images were built for (TVISA.md section 30.4). On systems whose cores differ in optional features, processes whose images use a feature present on only some cores are confined to those cores.

### 12.7 Frequency and idle

1. Frequency is chosen per cluster by the scheduler from decayed utilization, scaled up by the QoS boost of the running threads and by work-interval deadlines, and capped by thermal policy (section 26.4).
2. The idle governor chooses CPU idle states from predicted idle duration and the wake-up latency the current QoS mix tolerates. The kernel is tickless when a CPU is idle and when it runs one thread.

### 12.8 Load balancing

Each CPU has its own run queues. Balancing happens at wake-up (choosing the CPU), when a CPU becomes idle (pulling work from the busiest CPU of its cluster, then of the system), and periodically within clusters. Migration respects section 12.6.

### 12.9 Preemption

The kernel is fully preemptible. Preemption is disabled only while a spinlock is held and in per-CPU critical sections, which MUST NOT exceed 20 µs on reference devices; the continuous-integration tracing checks this.

### 12.10 Targets

| Measure (reference devices, loaded system) | Target |
| --- | --- |
| Wake-up to running, `UserInteractive`, 99th percentile | ≤ 50 µs |
| Release jitter, `Deadline`, 99.9th percentile | ≤ 20 µs |
| Thread switch within a process | ≤ 0.8 µs |
| Thread switch between processes | ≤ 1.2 µs |

---

## 13. Virtual memory

### 13.1 Address spaces

| Architecture | Page size | User range | Kernel range |
| --- | --- | --- | --- |
| aarch64 | 16 KiB | 0 to 2^47 (TTBR0, 4 levels with the 16 KiB granule) | Upper 2^47 (TTBR1); 2^52 with FEAT_LPA2 |
| x64 | 4 KiB | 0 to 2^47 (4-level), 2^56 with LA57 | Upper half |
| rv64 | 4 KiB | 0 to 2^47 (Sv48), 2^56 with Sv57 | Upper half |

### 13.2 Large pages

| Architecture | Sizes used |
| --- | --- |
| aarch64 (16 KiB granule) | 2 MiB through the contiguous hint (128 pages), 32 MiB blocks, 64 GiB blocks for the direct map |
| x64 | 2 MiB, 1 GiB |
| rv64 | 64 KiB through Svnapot, 2 MiB, 1 GiB |

Anonymous memory and the file cache use large pages transparently when a mapping is aligned and fully populated; the kernel splits and merges them as needed.

### 13.3 Memory objects

| Kind | Pages from | Notes |
| --- | --- | --- |
| Anonymous | Zero-filled on first touch | May be compressed or swapped |
| File | The TRFS pager (section 20.3) | Unified with the file cache |
| Clone | A parent object, copy-on-write | Created by `Memory.clone`; snapshots and private file mappings |
| Physical | Device memory or reserved RAM | `MmioRange` and firmware tables only |
| Contiguous | Physically contiguous RAM | For DMA buffers of devices that need it |
| Code | Loader images and memory sealed by the compile service | The only mappable-executable kind |

Operations: create, read and write without mapping, map, clone, resize, commit and decommit ranges, pin (for DMA), set cache policy (write-back, write-combining, uncached, device), mark purgeable, and seal (no further writes by anyone).

### 13.4 Mapping

1. `Memory.map` maps a range of a memory object into an address space with protections read, read-write or read-execute. Read-write-execute does not exist; read-execute requires a code object and the `Execute` right.
2. Mappings have guard regions where LibTessera asks for them (stacks, allocator spans).
3. Mapping at a fixed address is allowed only inside a range the process reserved.

### 13.5 Page faults

The fault handler resolves demand-zero pages, copy-on-write, file pages (with read-ahead sized by access pattern and QoS), compressed pages, swapped pages, and memory tags, and maps large pages when the fault's surroundings allow. A fault that cannot be resolved becomes an exception (section 11.4).

### 13.6 Compressed memory

Under pressure, the kernel compresses cold anonymous pages into a compressed pool in RAM: LZ4 for pages compressed on the reclaim path, zstd at level 1 when the background compactor recompresses long-unused pages. Pages are decompressed on fault. Memory tags are compressed alongside their pages.

### 13.7 Swap

On laptops, desktops and servers, the compressed pool's coldest segments may be written to an encrypted swap file on TRFS, encrypted with a per-boot ephemeral key that never leaves the kernel. Phones, tablets, consoles and home devices never swap.

### 13.8 Purgeable memory

Purgeable objects marked volatile may have their pages discarded under pressure instead of being compressed; marking them non-volatile reports whether they survived.

### 13.9 Randomization

| Region | Entropy (bits), aarch64 / x64 / rv64 |
| --- | --- |
| Executable and framework images | 28 / 28 / 28 |
| Stacks | 30 / 30 / 30 |
| Heap regions (`libtirrt` spans) | 30 / 30 / 30 |
| GPU address space (Ember) | 24 / 24 / 24 |
| Kernel image | 18 / 18 / 18 |

### 13.10 Memory pressure and jetsam

1. Processes are in bands, from highest to lowest: system-critical, foreground, visible, audio and media playback, background, suspended, cached.
2. The kernel signals pressure levels `Warning` and `Critical` to processes through LibTessera, starting with the lowest bands.
3. When reclamation (purging, compression, swap where allowed) cannot keep free memory above the critical threshold, jetsam terminates processes from the lowest band upward, largest footprint first within a band, and records a jetsam event for each.
4. Each application has a footprint limit per device class, set by system policy; exceeding it terminates the process with a jetsam event of reason `FootprintLimit`.
5. System-critical processes are never jetsammed; if they would have to be, the system panics with a diagnostic, because the configuration is wrong.

### 13.11 Memory tagging

On CPUs with MTE, each process runs with tag checking enabled for its heap (TIR.md section 27.4): synchronous for system processes, drivers and development builds, asymmetric for applications. The kernel saves and restores tags with compression and swap, and checks tags on kernel accesses to user memory through the copy routines.

### 13.12 Shared virtual addressing with devices

When a GPU or other device needs shared virtual addressing (Ember.md section 8.1), the kernel binds the process's page tables to the device's PASID (substream on SMMUv3) and services device page requests (PRI and ATS) like CPU faults, with the same permissions.

### 13.13 Footprint

A process's footprint is its resident private memory, its compressed memory at compressed size, its GPU memory, and the kernel memory charged to it (page tables, handles, objects, IPC buffers). Footprint is what jetsam limits and what LibTessera reports.

### 13.14 Kernel address space

The kernel maps physical memory in a non-executable direct map, keeps kernel stacks, per-CPU areas and the allocator's regions in separately randomized ranges, and maps its code read-execute with BTI or IBT landing pads. Kernel code never executes from writable memory, and kernel page tables for code are made read-only after boot.

---

## 14. Kernel memory allocation

### 14.1 Entry points

TIR's heap instructions in the kernel profile (TIR.md section 31.1) lower to these entry points:

| Entry point | TIR instruction |
| --- | --- |
| `Tarwin.Allocator.allocate(size, alignment, type, flags) -> ptr` | `heap.alloc.raw` |
| `Tarwin.Allocator.allocateCounted(size, alignment, descriptor, type, flags) -> ptr` | `heap.alloc.counted` |
| `Tarwin.Allocator.allocateUnique(size, alignment, descriptor, type, flags) -> ptr` | `heap.alloc.unique` |
| `Tarwin.Allocator.reallocate(ptr, size, alignment, flags) -> ptr` | `heap.realloc.raw` |
| `Tarwin.Allocator.free(ptr)` | `heap.free.raw`, and destruction of unique and counted objects |
| `Tarwin.Allocator.retain(ptr)`, `release(ptr)` | Counted references |
| `Tarwin.Allocator.weakNew(ptr)`, `weakLoad(ptr)`, `weakRelease(ptr)` | Weak references |

`type` is the `typeid` of the allocated TIR type; `flags` select `Sleepable` or `AnyContext` allocation.

### 14.2 Type isolation

Allocations are served from zones keyed by size class and type bucket, where the bucket is derived from the `typeid`. Virtual address ranges given to a zone are never reused by another zone, even after their pages are freed, so a dangling pointer to one type can never reach an object of another.

### 14.3 Initialization and tagging

All kernel allocations are zero-filled. On CPUs with MTE, the kernel heap is tagged with random tags, retagged on free, and checked synchronously; elsewhere freed memory is held in a quarantine before reuse.

### 14.4 Structure

Per-CPU caches front each zone; the page allocator is a buddy allocator with per-CPU page lists; contiguous allocations come from reserved regions sized at boot; allocations larger than 64 KiB are mapped individually with guard pages.

### 14.5 Context and failure

`AnyContext` allocations never sleep and fail when no memory is immediately available. `Sleepable` allocations wait for reclamation. The kernel has no out-of-memory killer of its own: jetsam (section 13.10) runs in its own kernel thread and frees memory by terminating processes. Kernel memory is charged to the job on whose behalf it is allocated.

---

## 15. Synchronization

### 15.1 Kernel locks

| Primitive | Use |
| --- | --- |
| `SpinLock` | Short critical sections; variants that also mask interrupts |
| `Mutex` | Sleeping lock with adaptive spinning and priority inheritance |
| `RwLock` | Sleeping reader-writer lock with writer preference and priority inheritance |
| `SeqLock` | Read-mostly data with retrying readers |
| `Epoch` | Deferred reclamation: readers enter an epoch without locking; writers free memory after every CPU has left the epochs that could see it |
| `WaitQueue`, `Completion` | Blocking until a condition |

Debug images build the kernel with lock-order validation, which records the order in which lock classes are taken and panics on a cycle.

### 15.2 Wait on address

`Sync.wait32`, `Sync.wait64` and `Sync.wake` (LibTessera.md section 7.4) queue waiters on a hash of the physical page and offset, so waiting works across processes on shared memory. A 32-bit word that holds an owner thread identifier in its low bits with a waiters flag enables priority inheritance: the waiter's scheduling context is propagated to the owner.

---

## 16. Inter-process communication

### 16.1 Channels

Channels follow LibTessera.md section 10: bidirectional, message-oriented, each message carrying up to 64 KiB of bytes and up to 64 handles, in LibTessera's IPC wire format. Writing to a channel copies the bytes once into the kernel's message buffer (or, for messages of 16 KiB or more whose buffers are page-aligned, transfers the pages copy-on-write) and moves the handles, with their rights, out of the sender's table. A channel's queue is bounded (default 1,024 messages); a full queue returns `ShouldWait` and asserts `WRITABLE` when space frees.

### 16.2 Events

`Event` and `EventPair` objects carry user signals; an `EventPair` asserts `PEER_CLOSED` when its peer is destroyed.

### 16.3 Ports

Ports are completion queues (LibTessera.md section 5), optionally with rings (section 10.5). Any thread may wait on a port; waiting threads form a work pool, woken one per completion.

### 16.4 Synchronous calls

1. A `Service` object is bound to the server end of a channel. Server threads wait in `Service.receive`.
2. `Channel.call` sends a message and waits for the reply. When a server thread is waiting, the kernel switches directly from the caller to the server on the same CPU, without going through the run queue, and runs the server on the caller's scheduling context (section 12.5). `Service.reply` switches directly back.
3. Messages of up to 128 bytes and 4 handles travel in registers and a per-thread message area, with no copy through kernel buffers. Larger messages use the channel path.
4. Round trip of a 64-byte call and reply between two processes on one CPU: ≤ 0.6 µs on reference devices.
5. RIDL services implemented over channels use this path; LibTessera's RIDL channel transport chooses it automatically for request–reply calls.

### 16.5 Peer death and cancellation

Closing a channel end asserts `PEER_CLOSED` on the other end and fails pending calls with `PeerClosed`. A caller's deadline expiring cancels its call; the server's reply to a cancelled call is discarded.

---

## 17. Time and timers

### 17.1 Clocks

| Clock | Meaning |
| --- | --- |
| `Monotonic` | Time since boot, not advancing during system sleep |
| `Boot` | Time since boot, including sleep |
| `UTC` | Wall-clock time, set only by the time service through the `Clock` resource; leap seconds are smeared over 24 hours |
| `ThreadCpu`, `ProcessCpu` | CPU time consumed |

Sources are the architectural counters: `CNTVCT_EL0` on aarch64, the invariant TSC on x64, `time` on rv64, calibrated at boot against the firmware-reported frequency and, where available, a second reference. Every process maps the kernel time page (section 10.4), from which LibTessera computes `Monotonic`, `Boot` and `UTC` without a system call. The time service slews UTC at most 500 ppm and steps it only at boot or by explicit administrative action.

### 17.2 Timers

1. Timer objects fire at a deadline on a clock with a slack the caller states or the thread's QoS implies: up to 1 ms for `UserInteractive`, 5 ms for `Default`, 10% of the interval (at most 1 s) for `Background`. The kernel coalesces timers within their slack to minimize wake-ups.
2. Timers marked as wake sources wake the system from sleep (section 26.2); others are deferred while the system sleeps.
3. Deadline timers are programmed on the per-CPU architectural timer (generic timer, TSC-deadline, Sstc `stimecmp`); there is no periodic tick on idle CPUs or on CPUs running a single thread.

---

## 18. Interrupts, exceptions and traps

### 18.1 Interrupt controllers

| Architecture | Controller | Notes |
| --- | --- | --- |
| aarch64 | GICv3 or GICv4.1 with ITS | LPIs for MSI; pseudo-NMI for the watchdog and profiling |
| x64 | x2APIC, IOAPIC; interrupt remapping in the IOMMU | Interrupt remapping is mandatory: devices cannot target arbitrary vectors |
| rv64 | AIA: IMSIC per hart, APLIC for wired interrupts | MSIs delivered through IMSIC interrupt files |

### 18.2 Delivery to drivers

1. A device interrupt bound to an `Interrupt` object is acknowledged and masked by the kernel's handler, which then posts a completion to the port the driver bound it to. The driver handles the device and calls `Interrupt.complete`, which unmasks it.
2. Interrupt-to-driver-thread wake-up latency: ≤ 5 µs on reference devices at the driver's QoS.
3. MSI and MSI-X vectors are allocated per `DeviceSlot`, routed to the CPUs on which the driver's threads run, and remapped by the IOMMU.

### 18.3 Inter-processor interrupts and TLB maintenance

The kernel uses IPIs for rescheduling, remote function calls and stopping CPUs. TLB invalidation uses broadcast instructions where the architecture has them (`tlbi … is` on aarch64, `invlpgb` and `tlbsync` on x64 CPUs that support them, `sinval.vma` with Svinval on rv64) and IPIs otherwise. Address-space identifiers (ASIDs, PCIDs, ASIDs on rv64) avoid flushes on switches.

### 18.4 Exceptions

Exception entry saves the interrupted context, applies the CPU's speculative-execution mitigations for the transition (section 25.8), and dispatches. User faults follow section 11.4. Kernel faults are either expected faults in copy routines (section 10.3) or panics (section 30).

### 18.5 Machine checks and memory errors

Correctable memory errors are counted per page; a page whose count crosses a threshold is retired. An uncorrectable error in a user page terminates the processes mapping it (with reason `MemoryError`) and retires the page; in kernel memory it panics.

---

## 19. Device access and the kernel side of DeviceKit

### 19.1 Enumeration

The kernel enumerates the firmware-described devices (ACPI namespace or device tree) and PCIe hierarchies (ECAM configuration space), and keeps a device registry: each device's identity, resources, power capabilities, IOMMU group and parent. The DeviceKit manager reads the registry and its changes (hot-plug, removal, surprise removal) through its `DeviceRoot` resource. Matching drivers to devices is DeviceKit's (DeviceKit.md).

### 19.2 Device slots

The DeviceKit manager creates a `DeviceSlot` for a device and grants it to the driver process it launches. A slot gives access to exactly one device (or one IOMMU group, when the hardware cannot isolate its members):

| Operation | Meaning |
| --- | --- |
| `DeviceSlot.mmioRanges()` | `MmioRange` handles for its register regions |
| `DeviceSlot.interrupts()` | `Interrupt` handles for its wired interrupts; `allocateVectors(count)` for MSI and MSI-X |
| `DeviceSlot.iommuDomain()` | Its `IommuDomain` |
| `DeviceSlot.configRead`, `configWrite` | PCIe configuration access, filtered: writes that move BARs, change bus numbers, alter ACS or disable the IOMMU's control are refused |
| `DeviceSlot.setPowerState(state)` | D0 to D3cold through PCI power management and ACPI or device-tree power domains |
| `DeviceSlot.reset(kind)` | Function-level, bus or platform reset |
| `DeviceSlot.firmwareCall(…)` | Firmware services for the device (ACPI methods, SCMI messages) |

Clocks, resets, regulators and pin control that are not firmware-managed are provided by platform drivers in user space, themselves DeviceKit drivers, through DeviceKit's platform services.

### 19.3 MMIO

`MmioRange.map` maps registers into the driver with device memory attributes: Device-nGnRE on aarch64, uncached on x64, I/O memory attributes on rv64; or write-combining for frame-buffer-like apertures when the driver asks. MMIO mappings are never executable and never shared with another process except as doorbell grants (section 22.3).

### 19.4 DMA and the IOMMU

1. Every slot has its own IOMMU domain. A device can reach only memory mapped into its domain.
2. `DmaBuffer.create(domain, memory, range, direction)` pins a Memory object range and maps it at an I/O virtual address the kernel chooses at random within the domain; the driver receives the address.
3. Unmapping invalidates the IOTLB (and device ATCs) before the pages can be reused, always. There is no deferred invalidation.
4. Peer-to-peer DMA between devices (for example, storage to GPU memory) maps one device's memory aperture into another's domain, only when both slots' drivers agree through DeviceKit and the platform's ACS and IOMMU configuration keep the transfer isolated.
5. Shared virtual addressing for devices uses PASIDs bound to process page tables (section 13.12).

### 19.5 Rings

Kernel subsystems exchange requests with drivers through rings (Appendix A.4): fixed-size descriptor rings in shared Memory with producer and consumer indices, one ring pair per hardware queue. Notifications in each direction use an `Event` signal only when the other side has declared itself idle; a busy driver or a busy kernel subsystem polls the indices. The block layer (section 20.2) and the network stack (section 21.4) use rings.

### 19.6 Driver restart

When a driver process terminates or DeviceKit's watchdog declares it hung:

1. The kernel revokes the slot's MMIO mappings and DMA mappings, quiesces the device's interrupts, and resets the device (function-level reset where available, otherwise bus or platform reset).
2. Kernel subsystems keep their outstanding requests. Block requests not completed are kept in order; network transmit queues are kept; nothing returns an error to applications yet.
3. DeviceKit starts a new driver instance and grants it the slot. The kernel resubmits outstanding block requests (each request is idempotent at its logical block address) and resumes network queues; TCP retransmits whatever was lost in flight.
4. Objects applications hold (files, endpoints, streams) stay valid. Streams of user-space subsystems report the gap with `OVERRUN`.
5. If the device has gone, pending operations complete with `DeviceRemoved`.
6. Budgets: storage restart ≤ 500 ms, network ≤ 1 s, from the failure to resumed I/O.

---

## 20. Storage

### 20.1 Block devices

Storage drivers (NVMe, UFS, virtio-blk, USB mass storage) register block devices with the kernel through block rings, one per hardware queue. The block layer issues reads, writes, flushes, forced-unit-access writes, discards, write-zeroes, zone operations on zoned devices, and atomic writes where the device supports them.

### 20.2 Scheduling

Requests are queued by the issuing thread's QoS. `UserInteractive` and `UserInitiated` requests bypass queued `Utility` and `Background` work; `Background` I/O is throttled to a share of device bandwidth that rises when the device is idle and falls when foreground I/O is pending. Target: a `UserInteractive` 4 KiB read waits at most one in-flight request per queue behind lower classes.

### 20.3 TRFS

TRFS (TRFS.md) runs in the kernel. Its pager supplies the pages of file memory objects (section 13.3), so the file cache and memory are one. TRFS's encryption keys are kernel objects derived through the security service (section 25.7); drivers never see plaintext of encrypted data or the keys that protect it:

1. When the storage controller supports inline encryption with hardware-wrapped keys (keys that the controller can use but software cannot read), the kernel programs wrapped keys into it.
2. Otherwise the kernel encrypts and decrypts data itself (AES-256-XTS for data at rest, with the CPU's AES instructions) before buffers reach the driver.
3. Inline encryption that would require giving raw keys to the driver is not used.

### 20.4 Nodes and files

`Node` and `File` objects (LibTessera.md section 13) are kernel objects over TRFS and other mounted file systems. A `Node` is a capability to one file or directory; name resolution happens only relative to a `Node`, never escapes it (no `..` above it, symbolic links resolved inside it), and checks the handle's rights. Applications have no path namespace; the Namespace service mints `Node` handles with its `Namespace` resource.

### 20.5 Other file systems

File systems other than TRFS (exFAT and FAT for removable media, network file systems, archive views) run as user-space file-system servers that speak the file-system ring protocol (Appendix A.5) with the kernel; the kernel presents their contents as `Node` and `File` objects with the same capability semantics and caches their data in memory objects.

---

## 21. Networking

### 21.1 Stack

The kernel implements IPv6 and IPv4, neighbor discovery and ARP, ICMPv6 and ICMP, SLAAC and router advertisements, TCP (RFC 9293 with SACK, timestamps, window scaling, RACK-TLP, accurate ECN and L4S; BBRv3 by default, CUBIC selectable; Multipath TCP v1), UDP with segmentation and receive offload in both directions, and multicast. DHCPv4 and DHCPv6 clients, DNS, TLS, QUIC and VPN protocols run in user space.

### 21.2 Endpoints

`Endpoint` objects (LibTessera.md section 15) are the kernel's sockets. Operations are submitted through port rings. Sends of large buffers pin pages and transmit without copying; receives may use buffers registered in advance, which the network stack fills directly.

### 21.3 Policy

1. Creating an endpoint requires the matching entitlement: `tessera.network.client` for outgoing connections, `tessera.network.server` for listening, `tessera.network.local` for link-local and multicast discovery.
2. The network service, holding the `Network` resource, installs per-application policy: which interfaces an application may use (for example, no cellular data), and filtering rules. Filters run as packet-filter probes (section 27).
3. VPN applications with `tessera.network.vpn` receive tunnel endpoints: the kernel routes the traffic the VPN configuration selects into the application's tunnel ring and accepts its decapsulated packets.

### 21.4 Interfaces and drivers

Network interface drivers (Ethernet, Wi-Fi, cellular, USB, virtio-net) register interfaces through network rings with one ring pair per hardware queue, receive-side scaling, and the offloads the hardware has (checksum, TCP and UDP segmentation, receive coalescing, VLAN). Wi-Fi association, authentication and cellular session management happen in the drivers and their services; the kernel sees interfaces.

### 21.5 Queueing

Each interface's transmit path uses fair queuing per flow with pacing from departure times set by congestion control, which QUIC in user space uses through a per-packet transmit time. Endpoint traffic carries the QoS of the thread that created it: `Background` traffic yields to other traffic on congested links.

### 21.6 Targets

| Measure (reference devices) | Target |
| --- | --- |
| TCP throughput, one flow, 100 GbE server | Line rate with ≤ 4 cores |
| TCP request-response round trip over loopback | ≤ 8 µs |
| UDP small-packet rate per core | Within 5% of Linux with io_uring on the same hardware |

---

## 22. GPU and accelerator support

### 22.1 Memory

1. GPU drivers allocate system memory for GPUs as Memory objects and map them into devices through `DmaBuffer`s. Device-local memory (VRAM) is described to the kernel by the driver as physical memory objects over the device's memory aperture, which the driver maps into client processes (for CPU access through resizable BARs) on Ember's request.
2. GPU memory allocated on behalf of a process is charged to that process's footprint (section 13.13): the driver attributes each allocation to the client's `Process` handle.
3. Process GPU address spaces are the driver's (Ember.md section 29.3); for shared virtual addressing they use the process's page tables (section 13.12).

### 22.2 Fences

`Fence` objects (LibTessera type 16) are timelines: a 64-bit value in memory visible to CPUs and devices, and a kernel wait queue keyed by value. Holders with `Signal` (drivers) advance the value from interrupt or firmware-message handling; holders with `Wait` sleep until a value is reached. Fences can be exported to other processes. Ember's shared events are fences.

### 22.3 Doorbells

A GPU (or NPU, or other accelerator) driver may grant a client process a write-only, uncached mapping of a doorbell page from its `MmioRange` with `MmioRange.grantDoorbell(process, offset)`. Only pages the driver designates as doorbells can be granted; the kernel checks that the range is one page and records the grant so it is revoked with the driver's slot.

### 22.4 Scheduling hints

Fence waits propagate the waiter's QoS to the driver's completion handling threads, and presentation deadlines (Ember.md section 21) are passed to the driver as work-interval deadlines.

---

## 23. The hypervisor

### 23.1 Access

Creating virtual machines requires the entitlement `tessera.hypervisor` (VMMs, the Android subsystem, developer tools) or the `Hypervisor` resource. Tarwin runs at EL2 with VHE on aarch64, in VMX root or SVM host mode on x64, and in HS-mode on rv64.

### 23.2 Objects

| Object | Content |
| --- | --- |
| `VirtualMachine` | A guest physical address space (stage-2 tables, EPT or NPT, G-stage tables), its in-kernel interrupt controller and timers, its passthrough devices |
| `VirtualCpu` | One guest CPU, run by the thread that created it |

### 23.3 API

```
VirtualMachine.create(configuration) -> VirtualMachine
    // architecture, guest physical address bits, CPU feature set, interrupt controller kind,
    // confidential mode, nested virtualization
VirtualMachine.map(memory, offset, length, guestAddress, permissions)
VirtualMachine.unmap(guestAddress, length)
VirtualMachine.dirtyLog(range) -> bitmap, or a dirty ring
VirtualMachine.injectInterrupt(line or message)
VirtualMachine.assignDevice(slot)                     // with the Hypervisor resource or a DeviceKit grant
VirtualCpu.create(vm, index) -> VirtualCpu
VirtualCpu.getRegisters(set), setRegisters(set, values)
VirtualCpu.run() -> Exit
VirtualCpu.requestExit()
```

`Exit` reports one of: MMIO access (address, width, direction, data, the target register, decoded by the kernel on x64), port I/O (x64), hypercall (HVC, VMCALL or VMMCALL, SBI `ecall` from VS-mode), system-register or CSR access the kernel does not handle, wait-for-interrupt with no pending interrupt, guest exception the VMM asked to see, debug event, shutdown or reset request, and canceled run.

### 23.4 In-kernel devices

For performance the kernel emulates the interrupt controller (vGICv3 with ITS, using GICv4.1 direct injection where present; local APIC with APICv or AVIC posted interrupts; AIA with IMSIC guest interrupt files), the architectural timers (virtual counter offsets, TSC offset and scaling, `vstimecmp`), and the paravirtual clock. Everything else is emulated by the VMM.

### 23.5 Device assignment

A `DeviceSlot` can be assigned to a virtual machine: its DMA is translated by the IOMMU through nested stage-1 and stage-2 tables, its interrupts are posted to the guest, and its MMIO is mapped into guest physical memory.

### 23.6 Nested and confidential virtualization

1. Nested virtualization is specified and optional: on hardware with FEAT_NV2, VMCS shadowing or nested SVM, or the RISC-V nested H facilities, `configuration.nested` exposes virtualization to the guest; elsewhere it is unavailable.
2. Confidential virtual machines are specified and optional: Arm CCA realms, AMD SEV-SNP and Intel TDX, behind `configuration.confidential`, with attestation reports available to the guest.

### 23.7 Tarwin as a guest

Tarwin detects hypervisors and uses paravirtual devices (virtio and the paravirtual GPU), the paravirtual clock, steal-time accounting and paravirtual spin and yield hints.

### 23.8 Targets

| Measure (reference devices) | Target |
| --- | --- |
| MMIO exit round trip to the VMM and back | ≤ 2 µs |
| Hypercall handled in the kernel | ≤ 0.5 µs |
| Guest CPU-bound performance | ≥ 98% of bare metal |

---

## 24. The reference virtual machine monitor

### 24.1 tvmm

`tvmm` is Tessera's reference VMM, a system program written in Kira over the hypervisor API. It is what Tessera uses for the Android subsystem, development virtual machines, Tessera guests in Tessera Cloud Services, and other operating systems a user runs.

### 24.2 Machine

| Element | Specification |
| --- | --- |
| CPUs | Up to the host's count; topology and features the configuration selects from the host's |
| Memory | Guest RAM from anonymous memory objects; ballooning and free-page reporting |
| Bus | One PCIe host bridge with MSI and MSI-X; all devices are virtio 1.3 over PCI unless listed otherwise |
| Firmware | Tessera guests boot directly with the Tarwin boot protocol (section 6.6) and a virtual TPM; other guests boot UEFI firmware built through KLF, with Secure Boot and a virtual TPM 2.0 |
| Interrupts and timers | In-kernel (section 23.4) |

### 24.3 Devices

| Device | Notes |
| --- | --- |
| virtio-blk | Multi-queue, discard, write-zeroes; images on TRFS with copy-on-write snapshots |
| virtio-net | Multi-queue with offloads; NAT through the host network stack, or bridged with the `Hypervisor` resource |
| virtio-console, virtio-rng, virtio-vsock | |
| virtio-input | Keyboard, pointer, absolute tablet, multi-touch, from MosaicDisplay input routed to the VM's surfaces |
| virtio-sound | Through the host audio service |
| virtio-fs | Host folders the user granted through the picker, with DAX windows |
| virtio-iommu | For nested device assignment |
| virtio-balloon | Free-page reporting |
| GPU | `tessera.tvgpu` for Tessera guests (TVISA.md section 23); virtio-gpu with the Vulkan (Venus) context served by Vulkan on Ember for Linux and Android guests |
| Display | Each guest scanout, or each guest window through the guest agent, is a MosaicDisplay surface |
| virtio-pmem, PTP clock | Persistent memory and precise time |

### 24.4 Capabilities

Snapshots of complete machine state to TRFS (incremental, using TRFS clones), restore, live migration between hosts (Tessera Cloud Services), device and CPU hot-plug, and per-VM resource limits through its job.

### 24.5 The Android subsystem

The Android subsystem is a `tvmm` configuration running an Android guest built from the Android Open Source Project. A guest agent maps each Android app window to its own MosaicDisplay surface, bridges input, clipboard, notifications, audio, camera access through grants, and file access through picker grants (virtio-fs scoped to the granted folders). The guest runs with its own Android permission model inside, and as one sandboxed job outside.

---

## 25. Security

### 25.1 Principles

1. Authority comes only from handles. There are no user identifiers, groups, superuser or ambient permissions in the kernel.
2. Every executable page is signed code (section 25.3).
3. Every hardware security feature in section 5's mandatory column is enabled on every CPU before user code runs, and is never disabled for a process.
4. Drivers are untrusted and confined by the IOMMU.
5. Measurements describe exactly the software that runs (section 6.4).

### 25.2 Kernel hardening

| Protection | aarch64 | x64 | rv64 |
| --- | --- | --- | --- |
| Kernel never executes user memory | PXN on user mappings | SMEP | `sstatus` and page permissions |
| Kernel never accesses user memory except in copy routines | PAN | SMAP | `SUM` clear outside copy routines |
| Forward-edge integrity | BTI and type-tag checks (TVISA.md section 17.2) with kernel keys | IBT and type-tag checks | Zicfilp and type-tag checks |
| Backward-edge integrity | `paciasp` with kernel keys; GCS when present | Supervisor shadow stacks | Zicfiss in S-mode |
| Code pointers in memory | Signed with kernel keys and address diversity | | |
| Heap and stack safety | MTE on the kernel heap and on stack slots where present; type-isolated zones; zero-initialization; stack protector | Type-isolated zones, quarantine, zero-initialization, stack protector | Same as x64 |
| Read-only after initialization | Kernel code, read-only data, system-call table, exception vectors, kernel page tables for code | Same | Same |
| Protected data | Page tables, code-signing state, entitlement records, handle rights of resources: written only through the gated writer (section 25.2.1), with FEAT_S1POE permission overlays where present | Same, with PKS where present | Same |
| Address randomization | Section 7.6 | Same | Same |

#### 25.2.1 The gated writer

Protected data lives in pages the kernel maps read-only. One small component, the gated writer, changes it: it masks interrupts, makes a per-CPU writable alias of the target page (or opens a permission overlay or a protection key on hardware that has them), performs the validated write, closes the alias and restores interrupts. The gated writer validates every write against the invariants of the data it protects (a page-table entry may never make a page writable and executable, may never map a code page writable, and may never map kernel memory into user space).

### 25.3 Code signing

1. User-space executable pages come only from images the loader verified (section 7.2) or from code memory objects sealed by the compile service (TIR.md section 28.2), which the kernel accepts only from the process holding the compile-service role.
2. Code pages are verified on every page-in: the image's build identifier is a BLAKE3 hash, whose tree structure lets the kernel verify each page against the build identifier with the chaining values the loader keeps for the image, so an image modified on storage after loading is detected at the page that changed, and the process is terminated with `CodeSignatureInvalid`.
3. Trust stores:

| Signer | Signs | Accepted |
| --- | --- | --- |
| Tessera release key (hybrid Ed25519 and ML-DSA-65) | Boot sets, system images, system frameworks, pipeline-built applications and drivers | Always |
| Device key (in the TPM or secure element) | Images finalized by the compile service, probes, code produced by the JIT service | On this device only |
| Developer certificates (valid at most 182 days) | Development builds | In developer mode only |
| User-enrolled platform key | Boot sets and system images built by the user | On standard installations (section 25.6) |

4. Revocation lists ship with every train and are enforced at load.

### 25.4 Entitlements enforced by the kernel

| Entitlement | Governs |
| --- | --- |
| `tessera.tir.dynamic` | Executing dynamic CPU TIR through the compile service (TIR.md section 28.7) |
| `tessera.network.client`, `.server`, `.local`, `.vpn` | Endpoint creation (section 21.3) |
| `tessera.hypervisor` | Virtual machines (section 23.1) |
| `tessera.scheduling.realtime` | The `Deadline` class (section 12.3) |
| `tessera.memory.extended-limit` | A higher footprint limit for the application (section 13.10) |
| `tessera.ember.*` | Ember's entitlements (Ember.md section 32), enforced by GPU drivers through the kernel's entitlement query |

Entitlements for user-facing resources (camera, microphone, location, contacts) are enforced by the services that broker them, not by the kernel.

### 25.5 Certified and standard installations

1. Certified installations boot only Tessera-signed boot sets on devices whose root of trust Tessera provisioned; their attestations report `certified`.
2. Standard installations let the user enroll their own platform key, so they can boot self-built boot sets and system images. Every security mechanism of this section still applies, with the user's key as the release key; attestations report `standard`.
3. Developer mode and debug images are measured and appear in attestations.

### 25.6 Attestation

The security service, holding the `Security` resource, produces attestation statements: a TPM quote or DICE certificate chain over the boot measurements (section 6.4), a nonce, the device's identity key certificate, and the installation kind. Applications request attestation through LibTessera; Tessera's attestation verifier checks statements against known measurements.

### 25.7 Keys

Keys are kernel key objects that are never exported in clear: the hardware root key in the TPM or secure element; keys sealed to boot measurements; per-user keys unlocked by the user's credential through the security service; and the file-system keys TRFS derives (TRFS.md). Cryptographic operations with key objects run in the kernel (or in the secure element when it holds the key), and their results, never the keys, are returned.

### 25.8 Speculative execution

| Boundary | Mitigation |
| --- | --- |
| User to kernel | Branch-history clearing or the CPU's equivalent at entry; enhanced IBRS or the architecture's equivalent; return stack filling where the CPU needs it; no kernel data accessed speculatively from user-controlled indices without masking (TVISA.md section 17.9) |
| Process to process | Branch predictor barrier (IBPB or `sb` and context-specific prediction restriction instructions) when switching between processes that do not share a job |
| Guest to host | Full predictor and buffer flushes the CPU's vendor specifies on VM exit and entry |
| Same-core siblings | Core scheduling: SMT siblings run threads of the same job or idle, on CPUs vulnerable to cross-thread leaks |

The kernel keeps a table of CPU models and their required mitigations, versioned with the train, and applies the mitigations each CPU needs.

### 25.9 Sandbox

A process can reach exactly what its handles name. There is no global file namespace, no global network access without entitlements, no visibility of other processes except through handles its job grants, and no shared mutable kernel state between unrelated processes.

---

## 26. Power and thermal management

### 26.1 System states

| State | Description |
| --- | --- |
| Running | CPUs and devices managed dynamically |
| Suspend-to-idle | CPUs in their deepest idle state, devices in low-power states, memory in self-refresh, wake on configured interrupts |
| Connected standby | Suspend-to-idle with periodic and event wake-ups for network push and wake timers, on mobile devices |
| Off | |

Tarwin does not hibernate. Devices are required to sustain suspend-to-idle with low drain.

### 26.2 Wake

Wake sources are interrupts from devices DeviceKit marks wake-capable, timers flagged as wake sources, and network packets matching registered wake patterns. `WakeLock` objects (LibTessera.md section 18) keep the system or a subsystem awake; each is attributed to its process, and the power service sees who holds what.

### 26.3 Devices

Device power is managed by DeviceKit through slot power states (section 19.2). On system suspend, the kernel asks DeviceKit to suspend devices in dependency order and resumes them in reverse order.

### 26.4 Thermal

1. Thermal zones come from firmware tables and from sensor drivers. The kernel's thermal policy caps cluster frequencies, then restricts `Background` and `Utility` work, then caps `UserInitiated`, protecting `UserInteractive` and `Deadline` work for as long as the hardware's limits allow.
2. Processes see the thermal state (`Nominal`, `Fair`, `Serious`, `Critical`) through LibTessera and are expected to reduce work.
3. Skin-temperature targets apply to handheld devices, including when they are docked and driving a display.

### 26.5 Energy accounting

The kernel estimates each process's energy: CPU energy from the energy model and its run time per frequency, plus GPU, display and radio energy reported by drivers. The power service exposes it for battery usage reporting.

---

## 27. Probes: verified kernel extensions

### 27.1 Model

A probe is a TIR module in the kernel-probe profile, attached to a kernel hook. Probes are how Tarwin is extended at run time: there are no loadable modules.

### 27.2 The kernel-probe profile

1. Defined semantics only; managed trust class; no assembly, target intrinsics, raw pointer conversion or unmanaged instructions.
2. No recursion. Loops must have a bound proven by the verifier, and the whole probe has a verified worst-case instruction count of at most 1,000,000.
3. No heap. State lives in probe maps: arrays, hash tables, per-CPU arrays, and rings to user space, created as kernel objects with fixed capacities.
4. Access only to the hook's context structure and to the helper functions the hook type allows.

### 27.3 Hook types

| Hook | Context | Effect allowed |
| --- | --- | --- |
| Tracepoint | The tracepoint's record | Write maps and rings |
| Function entry and exit | Arguments and result of an exported kernel function | Write maps and rings |
| Scheduler events | Switches, wake-ups, migrations | Write maps and rings |
| System-call entry and exit | Call number, arguments, results | Write maps and rings |
| Block and file events | Requests and completions | Write maps and rings |
| Packet filter | A packet on an interface's ingress or egress | Verdict (pass, drop, redirect to an endpoint, mark) |
| Endpoint filter | A packet delivered to an endpoint | Verdict (pass or drop) |
| Security audit | Handle creation, entitlement checks, process creation | Write maps and rings |

No probe can change kernel state other than its maps, its rings and its verdict.

### 27.4 Compilation and loading

1. The compile service verifies the probe module against the profile, compiles it to native code for the kernel's CPU target under the kernel profile's code model and hardening, and signs it with the device key in the probe role.
2. Attaching a probe requires the `Probe` resource (held by the trace service and the network service) and a signed probe whose declared hook and maps match the attachment.
3. Overhead of an attached trivial probe: ≤ 50 ns per hook hit on reference devices.

---

## 28. Observability and debugging

### 28.1 Logging

The kernel logs through the system logging framework under subsystem `tessera.kernel`, with categories `boot`, `sched`, `vm`, `alloc`, `ipc`, `loader`, `security`, `device`, `block`, `trfs`, `net`, `gpu`, `hypervisor`, `power`, `thermal`, `probe`, `panic`, and the levels of LibTessera's `LogLevel`. Log lists set what is recorded per category, as for Ember (Ember.md section 6.4); a disabled entry costs one compare. Kernel log entries reach the logger service through a ring.

### 28.2 Tracing

Per-CPU trace rings shared with the trace service carry kernel trace events (context switches, wake-ups, interrupts, system calls, page faults, block and network I/O, fence signals, power state changes) and user trace events written by LibTessera's `Trace` calls into per-thread rings without system calls. Timestamps are `Monotonic`. The trace service exports traces in the Perfetto trace format.

### 28.3 Performance counters

`PerformanceSession` objects give access to CPU performance counters: per thread or process for its owner, system-wide with the `Debug` resource. Sampling records call chains from frame pointers and shadow stacks; statistical profiling extensions (Arm SPE, Intel PEBS, AMD IBS) are used where present.

### 28.4 Crashes and panics

1. User-space crashes produce reports (section 11.4) for the crash handler service.
2. A kernel panic writes a panic record of at most 1 MiB (registers of every CPU, backtraces, the tail of the kernel log and trace) to a reserved RAM region preserved across warm reset, and to the firmware's persistent error store where one exists; the logger service collects it at the next boot.
3. Debug images include a polled storage writer for the boot device that writes full kernel memory dumps to a dump partition.

### 28.5 Kernel debugging

Debug images include a kernel debugger stub speaking the GDB remote protocol (used by LLDB) over the network or a serial line; it stops all CPUs while connected. Release images contain no kernel debugger.

---

## 29. Updates and soft reboot

### 29.1 Installing a train

The update service downloads a train's boot set and system image delta, verifies them, applies the delta to a TRFS snapshot in the inactive slot, and marks the slot to boot next (section 6.5).

### 29.2 Updates without a kernel change

Each train records whether its kernel and LibTessera's system-call table differ from the previous train's. When they do not, the update service activates the new system image snapshot without rebooting: system services restart on the new snapshot, new processes start from it, and running applications continue on the old snapshot until they next launch. The old snapshot is retired when no process uses it. The new boot set still becomes the slot's boot set for the next boot.

### 29.3 Soft reboot

When the kernel changed, Tarwin restarts without returning to firmware:

1. Applications receive their termination lifecycle event and a deadline to save state.
2. The kernel loads the new boot set into reserved memory, verifies it, and extends PCR 12 with its hash.
3. DeviceKit quiesces every device; the kernel stops every process, masks interrupts, parks secondary CPUs, and jumps through a reserved trampoline into the new kernel with a boot information block equivalent to `tarboot`'s.
4. Target: from step 3 to the system services running again in ≤ 3 s on reference devices.

A full reboot through firmware happens when the train updates firmware or `tarboot`.

---

## 30. Panics, watchdogs and recovery

### 30.1 Panics

The kernel panics when an invariant is violated: an unexpected kernel fault, a failed internal assertion, a lock-order cycle on debug images, a kernel trap (`TARWIN-P` codes, section 35), memory corruption detected by tagging or the allocator, or the loss of a system-critical process. A panic stops other CPUs, writes the panic record (section 28.4), and reboots. Repeated panics on an unconfirmed slot exhaust its tries and fall back to the other slot.

### 30.2 Watchdogs

1. The kernel services the platform's hardware watchdog (Arm generic watchdog, the chipset watchdog, or the SoC's), so a kernel that stops scheduling is reset.
2. A soft-lockup detector flags a CPU that has not scheduled for 10 s; a hard-lockup detector using NMIs or pseudo-NMIs flags one that has not taken interrupts for 20 s. Both panic in release images.
3. `tessera.init` watches the system-critical services and restarts them; a service that cannot be restarted panics the system.

### 30.3 Recovery

The recovery boot set (section 6.5) can repair or reinstall both slots, erase the device after confirming the user's credential, and export diagnostics.

---

## 31. LibTessera on Tarwin

Tarwin is LibTessera's native backend. Every LibTessera guarantee is enforced by the kernel (the "native kernel" column of LibTessera.md section 21.4).

| LibTessera domain | Tarwin mechanism |
| --- | --- |
| Objects and handles (section 3) | Kernel objects and per-process handle tables with kernel-enforced rights (section 9) |
| Ports and completions (section 5) | Kernel ports with submission and completion rings (sections 10.5, 16.3) |
| Memory (section 6) | Memory objects and mappings (section 13) |
| Threads and synchronization (section 7) | Kernel threads (section 11.3), wait on address with priority inheritance (section 15.2) |
| Time (section 8) | The time page and timer objects (section 17) |
| Events (section 9) | `Event` and `EventPair` (section 16.2) |
| Channels and IPC (section 10) | Channels, wire format v1 unchanged, and synchronous calls (section 16) |
| Processes and jobs (section 11) | Section 11; the Launcher holds the `Launch` resource |
| The System channel (section 12) | Channels to system services |
| Namespace (section 13) | Kernel `Node`, `File` and `Watch` objects over TRFS and file-system servers (section 20.4); the Namespace service holds the `Namespace` resource |
| Grants and presence (section 14) | The Presence service; `Presence` handles are kernel objects whose rights never include `Transfer` or `Duplicate` |
| Network (section 15) | Kernel endpoints (section 21) |
| Device streams (section 16) | `Stream` objects: kernel-mediated rings between the service or driver producing the stream and the client, with rights and `OVERRUN` signaling enforced by the kernel |
| GPU and fences (section 17) | `GpuDevice` objects bound to the GPU driver's context channel, and kernel fences (section 22) |
| Power and thermal (section 18) | `WakeLock` objects, thermal and power state (section 26) |
| Random (section 19) | A kernel ChaCha20 generator seeded from the hardware source and the boot seed and reseeded continuously; LibTessera keeps per-thread generators seeded from it and reseeds them when the kernel reports a virtual-machine generation change (snapshot restore) |
| Diagnostics (section 20) | Logging, tracing and crash reporting (section 28) |

---

## 32. Limits

| Limit | Value |
| --- | --- |
| CPUs | 4,096 |
| Physical memory | 2^52 bytes |
| NUMA nodes | 64 |
| Processes (system) | 1,048,576 |
| Threads per process | 8,192 by default, 65,536 by job policy |
| Handles per process | 65,536 by default, 1,048,576 by job policy |
| Channel message | 65,536 bytes and 64 handles |
| Channel queue | 1,024 messages by default, 65,536 by option |
| Port pending user packets | 65,536 |
| Ring entries | 64 to 65,536, powers of two |
| Mappings per process | 1,048,576 |
| Memory object size | 2^46 bytes |
| Timers per process | 65,536 |
| Virtual machines per process | 64 |
| Virtual CPUs per machine | 512 |
| Probe worst-case instructions | 1,000,000 |
| Probe map capacity | 2^24 entries per map |

---

## 33. Versioning

1. Tarwin carries the train's version (`YY.M.W`). The first version is 26.11.1.
2. The system-call interface is private and specific to each train: LibTessera and the kernel of a train always ship together.
3. The kernel mechanisms drivers use (sections 19 to 22) are part of DeviceKit's Driver API. A kernel supports every Driver API version within DeviceKit's twelve-month window (DeviceKit.md), so drivers built against any of them keep working.
4. The boot information block (Appendix A.1) has a version. The kernel of train T accepts blocks from `tarboot` and from kernels of the 52 trains ending at T, so soft reboots across a year of trains work.
5. The hypervisor API is a LibTessera domain and follows LibTessera's versioning.
6. Every train's changes are recorded in `TARWIN-CHANGES.md` with the headings of TIR.md section 24.8 and `System calls`, `Driver API`, `Boot protocol`, `Security`.

---

## 34. Conformance and performance

### 34.1 Suites

| Suite | Content |
| --- | --- |
| Objects and IPC | Every object type, right and signal; handle lifetime; channel, port, ring and synchronous-call semantics; cancellation; peer death |
| System calls | Every call with valid and invalid arguments; continuous coverage-guided fuzzing of the system-call interface and of rings, on all three architectures |
| Scheduling | Fairness within classes, precedence and starvation bounds, deadline admission and budgets, priority inheritance and donation, work intervals, placement on heterogeneous CPUs, the targets of section 12.10 |
| Memory | Copy-on-write, file mappings, compression, swap, purgeable memory, jetsam ordering and limits, large pages, tagging preservation, shared virtual addressing |
| Allocator | Type isolation (no cross-type reuse), zeroing, tagging and quarantine, failure behavior |
| Loader and code signing | Every relocation kind; tampered images, tampered pages after load, expired and revoked signatures, wrong trains, wrong targets |
| Security | Exploit-mitigation tests: return-oriented and jump-oriented attacks, code-pointer substitution, shadow-stack violation, user-memory access from the kernel, page-table tampering through the gated writer; speculative-execution test suites per CPU model |
| Devices | DMA isolation (devices cannot reach unmapped memory), interrupt delivery, driver restart under load with fault injection, hot-plug and surprise removal |
| Storage | Crash consistency of TRFS through power-cut simulation; encryption paths; I/O QoS |
| Network | packetdrill TCP suites, IPv6 conformance, offloads, filters, VPN tunnels |
| Hypervisor | Guest boots of Tessera, Linux, Android and Windows; architectural test suites for virtualization; device assignment; nested and confidential virtualization where hardware allows |
| Power | 10,000 suspend-resume cycles per reference device; wake sources; thermal policy |
| Boot and update | A/B fallback, rollback protection, recovery, soft reboot, updates without reboot |
| Probes | Verifier positive and negative cases; hook semantics; overhead |

### 34.2 Performance gates

Measured on the reference devices of each train against the latest stable mainline Linux kernel on the same hardware, configured per its documentation for the workload, as the geometric mean of 10 runs.

| Benchmark | Requirement |
| --- | --- |
| Thread switch, wake-up latency, IPC round trip (against futex, pipe and Unix-socket ping-pong) | ≤ Linux |
| Anonymous and file page-fault latency | ≤ 1.05× Linux |
| Process launch to first instruction of `main` (against `posix_spawn` of an equivalent program) | ≤ 1.05× Linux |
| fio 4 KiB random read and write, queue depth 1 and 32; sequential 1 MiB | ≥ 0.95× Linux with io_uring |
| File metadata operations (create, look up, rename, delete) | ≥ 0.95× the faster of ext4 and btrfs |
| iperf3 TCP throughput; netperf TCP_RR; UDP packets per second | ≥ 0.95× Linux |
| SPEC CPU 2017 rate and speed (same compiler and options) | ≥ 0.99× Linux |
| Building the corpus of TIR packages with `tirc` | ≥ 0.95× Linux |
| Guest kernel build in a virtual machine | ≥ 0.95× KVM |
| Idle and video-playback power on battery devices | ≤ Linux |
| Interactive targets | Section 12.10 |

A gate missed on any architecture blocks the train.

---

## 35. Diagnostics

Codes have the form `TARWIN-<AREA><NNNN>`.

| Code | Meaning |
| --- | --- |
| `TARWIN-K0001` | Kernel code in `@AnyContext` calls sleeping code or allocates with sleeping flags (build error) |
| `TARWIN-K0002` | A kernel path's stack depth exceeds 80% of its stack (build error) |
| `TARWIN-K0003` | `unsafe` block without an invariant comment (build error) |
| `TARWIN-S0001` | System call from outside LibTessera's code (process terminated) |
| `TARWIN-S0002` | Code-signature failure at page-in (process terminated) |
| `TARWIN-S0003` | Attempt to create a writable-and-executable mapping (refused) |
| `TARWIN-S0004` | Entitlement missing for the requested operation (refused) |
| `TARWIN-S0010` | Footprint limit exceeded (jetsam) |
| `TARWIN-B0001` | Boot set signature invalid |
| `TARWIN-B0002` | Boot set below the anti-rollback version |
| `TARWIN-B0003` | Slot tries exhausted; falling back |
| `TARWIN-B0004` | Mandatory hardware feature missing |
| `TARWIN-D0001` | Device without IOMMU coverage (not granted to any driver) |
| `TARWIN-D0002` | Driver restart (with cause) |
| `TARWIN-D0003` | DMA fault: device accessed unmapped memory (driver restarted) |
| `TARWIN-H0001` | Hypervisor feature unavailable on this hardware |
| `TARWIN-P0001` | Unexpected kernel fault |
| `TARWIN-P0002` | Kernel assertion failed |
| `TARWIN-P0003` | Kernel memory corruption detected |
| `TARWIN-P0004` | Lock-order cycle (debug images) |
| `TARWIN-P0005` | System-critical process lost |
| `TARWIN-P0006` | Lockup detected |
| `TARWIN-P0007` | Uncorrectable memory error in kernel memory |

User-space faults are reported with TIR runtime codes (section 11.4).

---

## 36. Implementation plan

### 36.1 Packages

Tarwin is one Kira package tree, layered so that no package depends on a higher layer:

| Layer | Packages |
| --- | --- |
| 0 | `tarwin-arch-aarch64`, `-x64`, `-rv64` (entry, exceptions, page tables, context switch, in privileged assembly variant bodies), `kcore` |
| 1 | `tarwin-boot`, `tarwin-mm` (physical, virtual, allocator, compressor), `tarwin-time` |
| 2 | `tarwin-sched`, `tarwin-object` (objects, handles, rights), `tarwin-sync` |
| 3 | `tarwin-ipc`, `tarwin-syscall`, `tarwin-loader`, `tarwin-security` |
| 4 | `tarwin-device`, `tarwin-block`, `tarwin-net`, `tarwin-gpu`, `tarwin-power` |
| 5 | `trfs` (TRFS.md), `tarwin-hv`, `tarwin-probe`, `tarwin-trace` |
| Separate | `tarboot`, `tvmm`, LibTessera's native backend |

### 36.2 Milestones

| Milestone | Content | Exit test |
| --- | --- | --- |
| W0 | `tarboot`; boot on QEMU aarch64; memory, allocator, scheduler on one CPU; early console | Boots to a kernel shell-free self-test on QEMU |
| W1 | SMP; objects, handles, system calls; LibTessera native backend core; `tessera.init` | Object and IPC suites on QEMU |
| W2 | Virtual memory complete, loader, code signing, processes and jobs | Memory and loader suites |
| W3 | Synchronous IPC, port rings, work intervals, deadline class | IPC and scheduling suites |
| W4 | Device access, DeviceKit manager, virtio drivers, the paravirtual GPU | Device suite; Ember on the paravirtual GPU |
| W5 | Block layer, TRFS, network stack | Storage and network suites |
| W6 | Complete hardening, attestation, keys | Security suite |
| W7 | Power and thermal | Power suite |
| W8 | Hypervisor and `tvmm` | Hypervisor suite (Tessera and Linux guests) |
| W9 | x64 and rv64 parity | All suites on three architectures |
| W10 | First hardware platforms (an x64 desktop, an aarch64 laptop or development board) | All suites on hardware |
| W11 | Android subsystem | Android guest with per-app surfaces |
| W12 | Performance gates | Section 34.2 |

---

## 37. Appendix A: layouts

### A.1 Boot information block

All fields little-endian, block aligned to 4,096 bytes.

| Offset | Field |
| --- | --- |
| 0 | `u32` magic `54 42 49 42` ("TBIB"); `u8` year, `u8` month, `u8` week of the producing train; `u8` block revision |
| 8 | `u64` total size |
| 16 | `u64` physical address and `u64` entry count of the memory map; entries of 32 bytes: `u64` base, `u64` length, `u32` type (usable, reserved, firmware runtime code, firmware runtime data, ACPI reclaimable, ACPI NVS, persistent, boot set, boot information, panic record, unusable), `u32` attributes |
| 32 | `u64` RSDP physical address, or 0 |
| 40 | `u64` device tree physical address, or 0 |
| 48 | `u64` UEFI system table physical address, or 0 |
| 56 | Framebuffer: `u64` base, `u32` width, `u32` height, `u32` stride, `u32` format |
| 80 | `u64` boot set physical address, `u64` boot set size |
| 96 | `u8[64]` entropy seed |
| 160 | `u64` TCG event log address, `u64` event log size |
| 176 | `u8` slot (0 A, 1 B, 2 recovery), `u8` security state (bit 0 Secure Boot, bit 1 debug image, bit 2 developer mode, bit 3 standard installation, bit 4 soft reboot), `u16` reserved |
| 180 | `u32` reserved |
| 184 | `u64` kernel virtual base, `u64` kernel physical base |
| 200 | `u64` command options (bits defined per train; only options the boot set's signature allows) |
| 208 | `u64` previous kernel's panic record address, or 0 |
| 216 | Reserved to 4,096 |

### A.2 User address-space layout

| Region | aarch64 | x64 | rv64 |
| --- | --- | --- | --- |
| Null guard | `0` to `2^32` | `0` to `2^32` | `0` to `2^32` |
| Images (randomized) | `2^32` to `2^40` | same | same |
| Heap spans, stacks, mappings (randomized) | `2^40` to `2^46` | same | same |
| GPU address space reservation (Ember, randomized) | `2^46` to `2^47 − 2^36` | same | same |
| Kernel time page and LibTessera shared pages | Top 2^36 bytes of the user range | same | same |

### A.3 System-call registers

Section 10.2 is normative; this appendix adds that the argument block for calls with more arguments than registers is 8-byte aligned, holds the remaining arguments in order as 8-byte slots, and is passed in the last argument register.

### A.4 Ring format

A ring pair lives in one Memory object:

| Offset | Field |
| --- | --- |
| 0 | `u32` magic `54 52 4E 47` ("TRNG"), `u16` version 1, `u16` flags |
| 8 | `u32` entry count (power of two), `u32` entry size (64 or 128 bytes) |
| 64 | Request ring: `u32` producer index (cache-line aligned), `u32` consumer index (next cache line), `u32` producer-idle flag, `u32` consumer-idle flag |
| 320 | Completion ring: the same four fields |
| 4,096 | Request entries, then completion entries |

Indices increase without wrapping and are reduced modulo the entry count. A producer writes entries, then publishes the producer index with release ordering; a consumer reads the index with acquire ordering. A side signals the other through the ring's `Event` only when the other side's idle flag is set. Entry formats are defined per protocol: block (operation, flags, logical block, block count, buffer list by I/O virtual address, request identifier, QoS class), network (buffer address, length, offload flags, queue, packet identifier), file system (section A.5).

### A.5 File-system ring protocol

User-space file-system servers (section 20.5) receive requests and return completions over a ring pair, with operations: `lookup`, `getAttributes`, `setAttributes`, `read`, `write`, `create`, `remove`, `rename`, `readDirectory`, `link`, `symbolicLink`, `readLink`, `flush`, `sync`, `statFileSystem`, `watch`, and the extended-attribute operations. Data moves through Memory objects shared with the kernel's file cache; servers never receive capabilities beyond the volume they serve.

---

## 38. Appendix B: decision log

| Id | Decision | Reason |
| --- | --- | --- |
| TW-001 | Hybrid kernel: scheduler, memory, IPC, file system, network stack and hypervisor in the kernel; every device driver in user space | Linux-class performance for the hot paths, isolation and restartability for drivers |
| TW-002 | Written only in Kira, compiled through TIR's kernel profile | One language for the whole system; TIR's verification and hardening apply to the kernel |
| TW-003 | Capability handles are the only authority; no user identities in the kernel | No ambient authority; matches LibTessera |
| TW-004 | QoS classes with EEVDF inside, a deadline class with admission control, work intervals, energy-aware placement | Interactive responsiveness and battery life together |
| TW-005 | 16 KiB pages on aarch64, 4 KiB on x64 and rv64, transparent large pages | Fewer TLB misses on aarch64; Tessera's long-term architecture |
| TW-006 | Compressed memory everywhere; swap only on laptops, desktops and servers; jetsam with bands and footprint limits | Mobile-grade memory behavior and flash longevity |
| TW-007 | The kernel loads images; every executable page is signed and verified at page-in through the BLAKE3 tree | Code signing that survives storage tampering |
| TW-008 | System calls only from LibTessera's code, numbered per train | The system-call interface is private and free to evolve |
| TW-009 | Port rings for asynchronous operations; synchronous calls with direct switch and scheduling-context donation | Completion-based I/O without system calls, and microkernel-grade request–reply latency |
| TW-010 | `tarboot`, A/B slots with tries and anti-rollback, measured boot into PCRs 8 to 12 | Reliable updates and truthful attestation |
| TW-011 | Mandatory IOMMU, interrupt remapping, PAC and BTI, CET, Zicfiss and Zicfilp, SMEP, SMAP and PAN; MTE when present | Security without exceptions |
| TW-012 | Protected kernel data written only through a gated writer, with permission overlays or protection keys where present | Kernel write primitives cannot rewrite page tables or code-signing state |
| TW-013 | No inline encryption that exposes raw keys to drivers | Drivers never see keys or plaintext of encrypted data |
| TW-014 | TCP/IP in the kernel; TLS, QUIC and VPN protocols in user space | Kernel fast paths for transport, user-space agility for protocols |
| TW-015 | HVF-style hypervisor API with in-kernel interrupt controllers and timers; nested and confidential virtualization optional | Fast virtualization with user-space device models |
| TW-016 | `tvmm` is the reference VMM; other operating systems, including Android, run only as virtual machines | No compatibility layers inside the kernel |
| TW-017 | Probes are verified TIR compiled by the compile service and signed with the device key; no loadable modules | Safe extensibility for tracing and packet filtering |
| TW-018 | Updates without reboot when the kernel is unchanged; soft reboot otherwise | Weekly trains without weekly firmware reboots |
| TW-019 | Suspend-to-idle and connected standby; no hibernation | Instant resume; no plaintext-adjacent memory images on disk |
| TW-020 | Transparent driver restart with request replay | Driver crashes are invisible to applications |
| TW-021 | ELF64 as the image container under the Tessera profile, with kernel-processed loader records | Standard tooling for debugging and symbols; no dynamic-linker semantics |
| TW-022 | Performance gates against mainline Linux block a train | The 5% goal is enforced, not aspirational |

