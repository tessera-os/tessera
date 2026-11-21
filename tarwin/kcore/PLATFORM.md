# Platform implementation status — 26.11.1

The eight Swift packages keep freestanding source under `Sources/` and hosted tests under `tests/`. Run from the repository root on macOS using Swift 6.3.3:

    sh tessera-packages/tarwin/platform-tests.sh

Set `SWTPM_REPLAY=1` (requires swtpm) and `QEMU_TREES=1` (requires QEMU aarch64/riscv64 and dtc) for interop tests. Set `EMBEDDED_SWIFTC` to the swift.org release toolchain's swiftc to also compile each module as a non-allocating Embedded Swift ELF object for aarch64, x64 and rv64. Xcode's bundled toolchain may lack the bare-metal standard library modules. Nothing here links the hosted runtime into a kernel.

| Package | Portable code exercised by the host programs | Not implied |
| --- | --- | --- |
| kcore | Checked unsigned intervals and alignment | Kernel standard library or verified context/stack discipline |
| tarboot | Slot choice, counter transition calculation, version floor, TIRA members, UEFI table CRCs, descriptor ordering, exit retry semantics | Writing firmware variables, verifying member hashes or release signatures, recovery entry |
| tarwin-boot | Little-endian TBIB revision 1 encoder, streaming decoder, sorted memory map validation, SHA-256 TPM extend and TCG Event2 bytes, flattened device tree RAM and static reservations | Physical address ownership, train history validation, live CRB/TIS or DICE, CPU entry |
| arch packages | Stage-one user leaf descriptors and walk indices for the ordinary page granule on each ISA | Live page tables, TLB maintenance, trap/interrupt handling or an instruction executed on that ISA |
| tarwin-mm | Physical page arenas, mapping restrictions, A.2 regions, zero/copy/tag restoration, LZ4 blocks, file-cache leases, footprint, purge and jetsam selection | Live page faults, a running reclamation thread, TRFS backing, swap, zstd compaction or a kernel heap |
| tarwin-time | Integer counter conversion, slew and coalescence arithmetic, watchdog thresholds | Clock sampling, timer delivery, wake sources, or a watchdog interrupt |

### Integration constraints

1. A caller of `chooseSlot` must durably write the returned active slot and remaining attempts before entry when `persist` is true. All paths, including recovery, must authenticate and apply the monotonic floor. A candidate version alone cannot advance it.
2. Validate the aligned block's extent and fields before emitting bytes. Decode into private storage, accept only on completion, then validate the train and external physical references against the immutable memory map. Secure Boot and other state bits describe the handoff, not evidence of its origin.
3. `makeArena` consumes eligibility bits only from usable RAM after all permanent and temporary reservations. `takePages` returns physical ownership, not initialized user memory. No page is publishable without initialization and the gated page-table writer.
4. Descriptors have no privileged side effect. Only the authorized writer may install them and must perform architecture-specific synchronization and invalidation. Unsupported translation formats fail closed.
5. TRFS implements the `FilePager` lease on its unified file-cache frame. Pin through installation; release only after teardown and invalidation. These leases do not authorize executable mappings. Anonymous reclaim stores raw LZ4 blocks including packed allocation tags; do not evict on failure or unless storing the block saves memory. Restore into an unpublished frame and discard partial output on any error.
6. [Boot kernel preflight](../../tessera/build/tarwin/Sources/TarbootPreflight/KernelMember.swift) validates the TIRA directory, verifies the selected raw member’s BLAKE3-256 digest, and passes just that member to the loader’s ELF64 preflight. ELF note offsets are member-relative and valid only on the same pinned bytes. Neither the digest nor a signature note authenticates the archive; boot-set certificate verification, note policy, anti-rollback and verified mapping remain mandatory. Zstd members are reported as compressed, not inspected or accepted.

### Firmware and TPM interop

The TPM test sends a Swift-encoded PCR_Extend command to a fresh software TPM and checks PCR 8 against SHA-256 replay of its Event2 digest. The device-tree tests consume QEMU-generated trees. A separate [firmware probe](../tarboot/tests/FirmwareProbe/README.md) exercises UEFI exit, a real reserved physical page, and the [bootstrap run queue and clock binding](../../tessera/build/tarwin/Sources/TarwinBootstrap/BootCPU.swift) in all three QEMU guests. Dispatch uses test clock samples; there is no timer interrupt or context switch. The probe is not a signed Tarwin boot set or a kernel.

### Pending gates

The [KLF Swift preflight](../../tessera/build/tarwin-profile/README.md) compiles actual KCore input and fails on compiler diagnostics or a non-kernel profile. A standalone scalar function reaches app-profile emission; it is not relabeled as kernel.

Compiler object checks do not verify generic specializations for unknown future callers, kernel-profile TIR, interrupt/stack discipline or a linked kernel. W0 entry, firmware authentication, live page faults, three-ISA kernel execution, reference hardware, canonical TRFS and same-device performance comparisons remain unverified.
