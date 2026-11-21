# Tarwin 26.11.1 coverage

**Release: blocked.** Host-side Swift tests exercise the mechanisms below. They do not execute a Tarwin kernel. No §34 suite result or performance gate has been accepted on any reference ISA.

| Requirement | Available evidence | Required before marking implemented |
| --- | --- | --- |
| §§1–4 scope, goals and trust boundaries | Layered packages and [implementation decisions](decisions.md). Non-kernel VMM, device models, compiler analysis and exporter. | Audit the linked kernel and signed services; run all three ISAs. No weaker fallback or Linux compatibility layer. |
| §§5–8,13–14,17–18,29–30 / platform | [Platform ledger](../kcore/PLATFORM.md), portable package tests. | Kernel-profile Swift→TIR build/link, authenticated firmware handoff, MMU/interrupts, CPU entry, QEMU and physical bring-up. |
| §§7,9–12,15–16,25,31 / execution | Generated syscall index; object, loader, IPC, security, sync and scheduler package tests. | Match native calls and providers to object lifetime, native entry, paging, execution, jobs and service startup. |
| §§19–22,26 / devices and storage | [Device integration boundary](../tarwin-device/README.md), driver and block/GPU/pager tests. | Physical IOMMU, IRQ, revocation, reboot/recovery and all DeviceKit tests; normative TRFS disk-format reference. No btrfs substitution. |
| §23 hypervisor | VM admission, dirty bitmap collection, vCPU run/cancel, APIC/IMSIC state, clock/comparator, pin and assignment lifetimes. [QEMU execution](../tarwin-hv/tests/StageTwoHarness/README.md): VHE/EL1h, SVM long mode and HS/VS with actual nonidentity stage-2/NPT/G-stage RAM mappings, hypercalls and protection faults. Arm scalar and RV64 regular/compressed MMIO exits and guest load completion. Arm/RV trapped WFI and delegated register reads. GICv3 virtual IRQ acknowledgement/EOI and forwarded virtual timer PPI on Arm; VS IMSIC and hardware-emulated `vstimecmp` interrupts on RV64. Bochs VMX/EPT VMCALL and three protection faults. Separately linked debug kernels on the three QEMU ISAs run the Tarwin allocator and boot scheduler and render guest console text. | Tarwin boot-set integration with private VM pins, complete context save/restore, all-CPU shootdown/VMID reuse, production interrupt and timer routing, physical VMX/EPT execution, services, optional modes/attestation and full typed syscall dispatch. No signed W1/init or full Tessera/Linux/Android/Windows guest boot, or physical timing result. |
| §24 reference VMM | Single-bus PCI ECAM enumeration, guest BAR sizing and decode, virtio PCI capabilities, common-config and notify registers, split-ring execution from pinned guest pages, MSI-X masking and pending delivery, storage and network data paths, vsock credit tracking, PCM control, balloon/rng/pmem/input helpers, IOMMU range and DAX updates, 2D image/scanout control, hosted Metal clear/blit with grant-scoped textures and ordered completion, checkpoint ordering, app-grant routing. | Bootable tvmm executable with all device/service bindings; guest firmware bus description, translated DMA for the Tarwin guest driver and platform IRQ routing, UEFI/vTPM, full Metal guest rendering and Venus translation, firmware/time, TRFS clone and migration transport, CPU/device hot-plug and job charging. |
| §24.5 Android | Guest-agent window lifecycle and host channel with app-bound service grants, replay rejection, scoped input and disconnect cleanup. Hosted tests only. | AOSP image with trusted guest agent; MosaicDisplay, clipboard, notifications, audio, camera and scoped picker services in a running sandboxed VM. No guest permission substitutes for a host grant. |
| §27 probes | Hook-effect checks, fixed map bounds, a bounded fixed-record ring producer, bounded hash work, structured worst-case analysis and attach/drain ordering. | Compiler decode/range proofs on actual TIR bytes, hardening, device-role signing, immutable loader and native hook execution on each ISA. |
| §28 diagnostics | Ring publication, category-filtered kernel log records, bounded all-CPU panic capture with optional firmware mirroring, counter ownership/sampling logic, source-bound Perfetto ring draining with monotonic timestamps and backpressure; bounded commit-last panic TLV; standalone debug-stop/RSP inspection code. | Live Monotonic/PMU/trace hooks and logger; panic capture on every CPU, firmware error store, warm reset and polled dump; hardware halt/transport with LLDB, release image exclusion. |
| §32 limits | Individual domain tests and explicit limits on VM/vCPU/probe objects. | Exercise every published limit, one past, quota exhaustion, cleanup and concurrent use on each reference. |
| §33 versioning | [Train changes](../TARWIN-CHANGES.md), generated names and boot revision. | Train-matched native calls, Driver API twelve-month compatibility, authenticated TBIB history and hypervisor domain compatibility. |
| §34 suites and budgets | [Runnable collection and evidence checker](../conformance/README.md); binds a run to the full inventory and SHA-256 of every planned result and capture; blocks missing records, architectures and failed budgets. | Trusted lab adapter, approved physical reference inventory, immutable captures, separate sealed QEMU W0/W1 archives, W10 hardware form factors, all suites and ten trials on the same hardware with latest stable mainline Linux. |
| §35 diagnostics | Catalogued build/runtime conditions and owner package tests. | Capture each normative diagnostic **and** specified refusal, termination, restart or panic; a printed label alone is not evidence. |
| §36 packaging / milestones | Source package layout and provider boundaries; no host build is a milestone exit. | W0 boot; W1–7 services; W8 guest boots; W9 three-ISA parity; W10 physical hardware; W11 Android windows; W12 performance. All exits unverified here. |
| §38 App. B | TW-001–022 in [Tarwin 1.0](../../tessera/roadmap/Tarwin.md); train-specific choices in [decisions](decisions.md). | Check implementation and measurements against each decision, without weakening isolation. |

### I/O evidence and open gates

The [device package](../tarwin-device/README.md)
documents the cold Arm firmware-style queue reset and SMMUv3 all-abort stream
table. Both QEMU PCI requesters are denied their former queue pages with
either low MMIO or the pinned 512 GiB high MMIO window.

In the separate [Arm EFI guest fixture](../tarboot/tests/FirmwareProbe/README.md),
the platform owner observed `streamsDenied` after EDK2 ExitBootServices and
before copying the detached signature bytes on **both** layouts. With high
MMIO enabled, the guest checked all eight pages of the two BAR4s with
`AT S1E2W` for writable, identity-mapped Device memory before touching either
endpoint. This checks the CPU mappings; the hosted QEMU traces above test
DMA denial. Low-only remains the default. No signed image or W1/EL0 entry:
integration of that handoff with the signed launcher, protected work-page lifetime,
continuous exclusion across entry, and re-establishing DMA protection before
resuming restored devices are unverified. The platform's separate read-only
VMGENID aperture test exercises generation rotation, not restored DMA exclusion.
No hotplug, passthrough or physical
DMA/ATC evidence. DeviceRoot manager acquisition, native syscall/VM pins,
IRQ delivery, suspend/wake, hardware storage recovery, production TCP/IP,
native Metal/MosaicDisplay integration and same-hardware Linux budgets remain open.
The [filesystem fixtures](../trfs/README.md) cover mounted reads and encrypted
sector staging, **not** the missing normative TRFS format or durable recovery.

| Hosted QEMU (arm64, x64, rv64) | Demonstrated | Still unverified |
| --- | --- | --- |
| [virtio-net](../drivers/virtio/README.md) | Stable MAC, carrier, MTU; isolated two-NIC UDP; ARP/ND, SLAAC, active/passive TCP against libslirp. | Multi-queue/RSS, offloads, native guest bindings, full TCP conformance and physical line rate. |
| [virtio-gpu](../drivers/virtio/README.md) | Fenced 2D resource and backing lifecycle; every pixel of the captured QEMU scanout matches. | 3D/Venus and live Metal/MosaicDisplay, native guest services, physical fences, presentation deadlines and bandwidth. |

### How to repeat host tests

The [Mac presentation check](../conformance/metal-integration) runs the actual guest-driver
encoder, TVMM grant and sequence checks, and MosaicMetal render/blit executor on a Metal
command queue. All 3,072 BGRA8 pixels matched for each offscreen frame on the Apple
paravirtual GPU, both in the original surface and in the separate compositor output. TMC1
phase 1 follows rendering; phase 2 comes from the completed offscreen copy in the I/O v5
Mosaic compositor. No display latch is inferred. In a second run, allocation-disabled debug kernels
on Arm, x64 and RV64 emitted the commands and consumed both host receipts over a fixed-buffer
monitor relay. The guest's driver checked that the frame became reusable only after release.
These are real guest instructions and offscreen GPU work, not a signed W1 boot, native display
service, physical scanout or W4/W11 acceptance.

Arm and RV64 protection diagnostics also collect two successive CPU write epochs: a store
faults on a write-protected RAM page, the monitor marks it dirty and retries at the original
PC. Re-arming breaks the leaf mapping, waits for invalidation, installs the new access and
waits again without dropping its original pin. Multi-CPU and device DMA tracking remain open.

From this directory's parent, run `swift test --package-path <package>` on each package: `tarwin-hv`, `tvmm`, `tarwin-probe`, `tarwin-probe/compiler`, `tarwin-trace`, `tarwin-trace/export`, `tarwin-trace/debug-image` and `conformance`. On the Mac, SwiftPM uses the shared generated TarwinSyscall library. With a Swift toolchain that includes Embedded standard libraries, run `SWIFTC=/path/to/swiftc sh conformance/check-embedded.sh`. This compiles the hypervisor, probe, trace and separate debug-image components to freestanding objects for all three ISAs with heap allocation disabled. It does not link, boot or certify the kernel, or replace the KLF Swift kernel profile. In the debug package, only checksummed stop-query, captured-register and detach replies are tested; no live connection or arbitrary memory access is implied.

### Required composition inputs

The single-port virtio-console PCI model services both split queues. Its Mac tests submit RX and TX through the guest BAR, fill and release host-side buffers, and retry without a second guest kick. The on-target `tvmm.console` case requires actual bidirectional traffic between a booted guest and its grant-scoped host console under backpressure.

Panic capture uses the physical CPU limit (4,096), not the guest vCPU limit. It preserves complete register banks and at least the top frame of each available stack before sharing the remaining space among deeper frames. If the mandatory data cannot fit in 1 MiB it leaves the last committed record intact. This was tested with frozen snapshots, not a physical warm reset.

1. **Platform:** Freestanding kernel-profile compiler/linker, all-three-ISA privileged entry/exit with safe host-state restore, gated translation writers and acknowledged shootdowns, all-CPU rendezvous, per-CPU Monotonic/PMU providers. Ordinary hosted Swift code cannot install a guest translation or enter a vCPU.
2. **Execution:** The generated numbers exist. Resolve typed handles and rights, copy arguments into private storage, pin objects across operations, and install domain providers at composition. Do not route register values directly to a host callback or add private call numbers.
3. **Devices and storage:** A complete DeviceSlot group with nested IOMMU and interrupt remapping. Pin through invalidation; never emulate isolation by naming an address range. Need canonical TRFS, durable clones and authenticated migration ownership records.
4. **VMM services:** Grant-scoped host network/audio/files/display, TIR/TVISA verifier/translator, full Metal rendering, Vulkan/Venus translation and MosaicDisplay protocols, trusted guest firmware and guest images.
5. **Lab:** Approved serials and build IDs, aarch64/x64/rv64 physical machines, all workload corpora, same-machine mainline Linux comparison. None is replaced by a host fixture.
