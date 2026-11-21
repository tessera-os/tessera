# Platform implementation status — 26.11.1

The eight Swift packages keep freestanding source under `Sources/` and hosted tests under `tests/`. Run from the repository root on macOS using Swift 6.3.3:

    sh tessera-packages/tarwin/platform-tests.sh

Set `SWTPM_REPLAY=1` (requires swtpm) and `QEMU_TREES=1` (requires QEMU aarch64/riscv64 and dtc) for interop tests. Set `EMBEDDED_SWIFTC` to the swift.org release toolchain's swiftc to build the W1 dependency graph in Embedded mode, then compile the selected platform and composition sources separately with allocations forbidden for AArch64, x64 and RV64. The check excludes the Darwin-hosted backend. It does not claim all transitive dependencies or a linked kernel are allocation-free. Xcode's bundled toolchain may lack the bare-metal standard library modules.

| Package | Portable code exercised by the host programs | Not implied |
| --- | --- | --- |
| kcore | Checked unsigned intervals and alignment | Kernel standard library or verified context/stack discipline |
| tarboot | Slot choice, counter transition calculation, version floor, TIRA members, UEFI table CRCs, descriptor ordering, exit retry semantics | Writing firmware variables, verifying member hashes or release signatures, recovery entry |
| tarwin-boot | Little-endian TBIB revision 1 encoder, streaming decoder, sorted memory map validation, SHA-256 TPM extend and TCG Event2 bytes, flattened device tree RAM and static reservations | Physical address ownership, train history validation, live CRB/TIS or DICE, CPU entry |
| arch packages | Stage-one user leaf descriptors and walk indices for the ordinary page granule on each ISA | Live page tables, TLB maintenance, trap/interrupt handling or an instruction executed on that ISA |
| tarwin-mm | Physical page arenas, type-isolated small-object slabs with quarantine, mapping restrictions, A.2 regions, zero/copy/tag restoration, LZ4 blocks, file-cache leases, footprint, purge and jetsam selection | TIR heap entry points, MTE heap, live page faults, a running reclamation thread, TRFS backing, swap or zstd compaction |
| tarwin-time | Monotonic/boot/UTC shared page, bounded slews, absolute deadline conversion, watchdog thresholds | Every-process LibTessera integration, live power transitions or NMI lockup detection |

### Integration constraints

1. A caller of `chooseSlot` must durably write the returned active slot and remaining attempts before entry when `persist` is true. All paths, including recovery, must authenticate and apply the monotonic floor. A candidate version alone cannot advance it.
2. Validate the aligned block's extent and fields before emitting bytes. Decode into private storage, accept only on completion, then validate the train and external physical references against the immutable memory map. Secure Boot and other state bits describe the handoff, not evidence of its origin.
3. `makeArena` consumes eligibility bits only from usable RAM after all permanent and temporary reservations. `takePages` returns physical ownership, not initialized user memory. No page is publishable without initialization and the gated page-table writer.
   A monitored arena counts corrected errors per physical page and excludes
   a retired page even after the enclosing buddy allocation is released.
   Fatal reports require trusted reverse mappings: a user-only frame requires
   termination of all affected processes, while kernel or unknown use requires
   panic. These are dispositions, not evidence of live teardown or recovery.
4. Descriptors have no privileged side effect. Only the authorized writer may install them and must perform architecture-specific synchronization and invalidation. Unsupported translation formats fail closed.
5. TRFS implements the `FilePager` lease on its unified file-cache frame. Pin through installation; release only after teardown and invalidation. These leases do not authorize executable mappings. Anonymous reclaim stores raw LZ4 blocks including packed allocation tags; do not evict on failure or unless storing the block saves memory. Restore into an unpublished frame and discard partial output on any error.
6. [Boot kernel preflight](../../tessera/build/tarwin/Sources/TarbootPreflight/KernelMember.swift) validates the TIRA directory, verifies the selected raw member’s BLAKE3-256 digest, and passes just that member to the loader’s ELF64 preflight. ELF note offsets are member-relative and valid only on the same pinned bytes. Neither the digest nor a signature note authenticates the archive; boot-set certificate verification, note policy, anti-rollback and verified mapping remain mandatory. Zstd members are reported as compressed, not inspected or accepted.

### Firmware and TPM interop

The TPM test sends a Swift-encoded PCR_Extend command to a fresh software TPM and checks PCR 8 against SHA-256 replay of its Event2 digest. The device-tree tests consume QEMU-generated trees. A separate [firmware probe](../tarboot/tests/FirmwareProbe/README.md) exercises UEFI exit, a real reserved physical page, and the [bootstrap run queue and clock binding](../../tessera/build/tarwin/Sources/TarwinBootstrap/BootCPU.swift) in all three QEMU guests. Dispatch uses test clock samples; there is no timer interrupt or context switch. The probe is not a signed Tarwin boot set or a kernel.

The separate fixed, non-restorable AArch64 debug profile uses an independently
provisioned EFI verifier, two pinned enrollments and a fresh swtpm. The
firmware binds the frozen archive and configuration to live PCRs 8/9 before
installing any kernel. The original signed four-member fixture subsequently
entered its intake kernel, which independently reverified the boot set and
measured init into PCR 10. This did not run init, mount a signed system root
or prove production trust. Changing the retained archive or swapping the
detached PIO signature stopped the firmware before kernel installation.

### Clock and memory diagnostics

The AArch64 W1 private-image builder requires a kernel-owned coherent time
frame. Its first A.2 shared-region page is RO/NX in each unpublished root.
For UTC the clock service can schedule one insertion or deletion window in
Boot time. The 24-hour smear and ordinary discipline share the 500 ppm
budget, including during sleep; UTC timers invert the same interpolation.
This is a kernel clock primitive, not a source of authenticated leap notices.
The VHE clock probe uses that mapping code, not a signed launch. For the
per-CPU comparator, run `bash tests/ArmDeadlineProbe/run.sh` and
`bash tests/RvDeadlineProbe/run.sh` from `tarwin-time` with
`EMBEDDED_SWIFTC` set. Each services a real timer interrupt in the boot
queue and disarms for single-context or idle dispatch; neither switches a
live thread stack. Both guests also deliver two coalesced one-shots in one
IRQ, wake a parked scheduler context and disarm the comparator. In the
single-hart rv64 diagnostic a Goldfish RTC alarm wakes WFI through PLIC;
a non-wake timer does not program that alarm and is delivered after resume.
This is not device/system suspend. RV64 also refuses a profile without Sstc.
Set `AIA_RTC=1` for the single-hart supervisor APLIC/IMSIC profile.
The guest checks its firmware tree before any timer or controller access:
RTC source 11 must route through the S-mode domain to hart 0's supervisor
interrupt file. Both absent Ssaia and a machine-domain parent are refused. After a WFI
wake it exercises the device package's port binding: mask on interrupt, refuse
rearm while the one-slot port is full or for the wrong epoch, then deliver
the pending level on rearm. Both port packets identify vector 65. This uses
an exclusive cold domain and kernel-local port; it is not generic controller
discovery, a userspace driver or an end-to-end Interrupt.complete syscall.
With two harts, OpenSBI starts the other enumerated hart on a private stack;
two bounded counter rendezvous and a peer read of the published time page
are followed by an observed HSM stop. The frequency check brackets reads of
the Goldfish RTC and refuses a doubled DT timebase. Both devices use QEMU
virtual time, not independent physical oscillators. No thread migrates.
The separate EL2 `tests/ArmClockSMPProbe/run.sh` fixture starts the
firmware-enumerated secondary with PSCI CPU_ON, checks both CNTFRQ values
and CNTVCT against PL031 and two bounded rendezvous, reads the shared
page on that CPU, then observes AFFINITY_INFO return OFF after CPU_OFF.
A non-PSCI secondary is refused before CPU_ON. Both stacks are private;
this fixture is not a production secondary security setup or EL0 launch.
The x64 firmware probe (`TARBOOT_TEST_CPU=1 TARBOOT_TEST_TSC_REFUSAL=1`)
refuses QEMU TCG's unsupported CPU; positive x2APIC/TSC-deadline delivery
needs a capable machine. No periodic fallback is enabled.

With `ARM_WATCHDOG=1` the Arm deadline runner instead checks the single-CPU
SBSA watchdog. The guest validates both frames in its DT before any watchdog
MMIO. Nine distinct boot-queue dispatches feed the emulated device; a replay
does not. After dispatch stops, QEMU asserts WS0 and WS1, resets, and the
same guest boots again. Overlapping or absent frames produce no accesses.
This is not a production SMP health policy, NMI panic or physical reset test.

All three QEMU firmware diagnostics also build and read back a physical TBIB
with a RAW firmware seed, validated RSDP/XSDT or FDT, the randomized test
reservation, and the ESP archive. Its map tags exactly the loader's archive
and handoff reservations. Readback validates their extents, not kernel entry.

The [stage-0 W0 build](../../tessera/build/tarwin-stage0/README.md) uses Apple's
Embedded Swift compiler on macOS and A12's native image writer. It produces
a separate unsigned aarch64 kernel candidate for the signing pipeline.
The [KLF Swift preflight](../../tessera/build/tarwin-profile/README.md) applies to
the later self-hosted compiler transition and is not a stage-0 prerequisite.

Compiler object checks do not verify generic specializations for unknown future callers, kernel-profile TIR, interrupt/stack discipline or a linked kernel. Release boot, a signed userspace entry, live page faults, signed execution on all three ISAs, reference hardware, canonical TRFS and same-device performance comparisons remain unverified.
