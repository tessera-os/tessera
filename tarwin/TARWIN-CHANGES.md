# Tarwin changes

## 26.11.1

Initial development train; not certified. See [coverage](docs/coverage.md).

**Additions:** Platform handoff, memory, object, scheduling, IPC, loader, device and virtualization packages; user-space VMM device logic; bounded probe analysis; trace export and panic records; physical-reference acceptance controller.

**Removals:** The superseded Kira sources and package manifests for virtualization, probes, diagnostics and acceptance. No prior shipping ABI removed.

**Semantic changes:** None relative to a prior shipping Tarwin train.

**Development updates:** The VMM exposes guest PCI configuration, BARs, interrupt delivery and single-port virtio-console queues. Panic records budget backtraces across physical CPUs. The acceptance runner now binds capture hashes to the original inventory and collection; host tests and freestanding object checks do not supply target results.

**Encoding changes:** Initial TBIB rev. 1, private train-specific syscall index and panic-record rev. 1. No canonical TRFS disk encoding asserted here.

**Producer notes:** Use train-matched LibTessera and generated call names. Use non-allocating Embedded Swift on pre-heap and interrupt paths, Embedded Swift for other kernel code, and regular Swift for hosted tools. Kernel artifacts still require the KLF Swift TIR kernel profile. Keep debug-only code and host tools out of release images.

**System calls:** See [generated index](tarwin-syscall/Sources/TarwinSyscall/CallNumbers.swift) and [numbering contract](tarwin-syscall/decisions.md). VM/vCPU, probe and performance operations have names; they are not all linked into a running kernel.

**Driver API:** DeviceKit's twelve-month compatibility window is unchanged; hardware compatibility and recovery testing are pending.

**Boot protocol:** Revision 1 handoff uses Appendix A.1 TBIB; producer train requires the 52-train acceptance check. Firmware handoff and cross-train soft reboot are not verified.

**Security:** No passthrough without isolated MMIO, nested DMA translation and guest interrupt routing. Unavailable protected-guest modes must be refused. Probe publication requires scoped authority and authenticated immutable code. No security claim for an unbooted configuration.
