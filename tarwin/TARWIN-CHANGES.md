# Tarwin changes

## 26.11.1

Initial development train; not certified. See [coverage](docs/coverage.md).

**Additions:** Platform handoff, memory, object, scheduling, IPC, loader, device and virtualization packages; user-space VMM device logic; bounded probe analysis; trace export and panic records; physical-reference acceptance controller.

**Removals:** The superseded Kira sources and package manifests for virtualization, probes, diagnostics and acceptance. No prior shipping ABI removed.

**Semantic changes:** None relative to a prior shipping Tarwin train.

**Development updates:** The VMM exposes guest PCI configuration, BARs, interrupt delivery and single-port virtio-console queues. Panic records budget backtraces across physical CPUs. The acceptance runner now binds capture hashes to the original inventory and collection; host tests and freestanding object checks do not supply target results.

**Encoding changes:** Initial TBIB rev. 1, private train-specific syscall index and panic-record rev. 1. The [TRFS disk format](trfs/TRFS.md) is owned by TRFS.

**Storage diagnostic:** Three QEMU debug guests read the pinned TRFS fixture through a
read-only virtual disk. They verify every byte of the intact file page and refuse the
same page with one corrupted byte. This does not establish controller I/O or signed boot.

**Presentation:** Metal replaces the earlier Ember graphics target. TVMM validates the guest
driver's TMS1 clear/blit and TMC1 completion contract on a prebound client channel; it does
not add these commands to virtio-gpu. Hosted offscreen execution is separate from display
acceptance. Three QEMU debug kernels also exercise this exchange over a diagnostic monitor
relay using the Embedded guest driver. Separate receipts follow GPU rendering and the
compositor's completed offscreen copy; pixels are checked in both textures, not at scanout.
New acceptance receipts bind W0/W1 QEMU runs separately from physical devices.

**Probes and tracing:** Bounded fixed-size probe ring writes and source-bound Perfetto ring
draining are tested in isolation. Live signed probe attachment, PMU delivery and measured
hook overhead remain unverified.

**Hypervisor diagnostics:** The [three-ISA execution check](tarwin-hv/tests/StageTwoHarness/README.md) enters test guests under QEMU TCG and verifies second-level RAM permissions and revocation. Bochs separately executes the Intel VMX/EPT path. Debug-profile guest kernels exercise the allocator, scheduler and console on all three QEMU targets. Neither signed W1 nor physical acceptance is established.

**Producer notes:** Use train-matched LibTessera and generated call names. Use non-allocating Embedded Swift on pre-heap and interrupt paths, Embedded Swift for other kernel code, and regular Swift for hosted tools. Kernel artifacts still require the KLF Swift TIR kernel profile. Keep debug-only code and host tools out of release images.

**Dirty tracking:** Arm and RV64 debug monitors collect two consecutive write epochs on a
private guest RAM page without dropping the backing pin. DMA tracking, multi-CPU shootdown
and production snapshot restore are not established.

**System calls:** See [generated index](tarwin-syscall/Sources/TarwinSyscall/CallNumbers.swift) and [numbering contract](tarwin-syscall/decisions.md). VM/vCPU, probe and performance operations have names; they are not all linked into a running kernel.

**Driver API:** DeviceKit's twelve-month compatibility window is unchanged; hardware compatibility and recovery testing are pending.

**Boot protocol:** Revision 1 handoff uses Appendix A.1 TBIB; producer train requires the 52-train acceptance check. Firmware handoff and cross-train soft reboot are not verified.

**Security:** No passthrough without isolated MMIO, nested DMA translation and guest interrupt routing. Unavailable protected-guest modes must be refused. Probe publication requires scoped authority and authenticated immutable code. No security claim for an unbooted configuration.
