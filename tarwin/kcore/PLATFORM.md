# Platform implementation status — 26.11.1

Run `sh tessera-packages/tarwin/platform-tests.sh` on a host with Kira and its matching KLF distribution. Set `KIRA` to the driver path and `KLF_HOME` to the extracted KLF distribution when not using knvm. Kira 26.10.4 on macOS arm64 builds these as host executables, not kernel images.

| Package | Portable code exercised by the host programs | Not implied |
| --- | --- | --- |
| kcore | Checked unsigned intervals and alignment | Kernel standard library or verified context/stack discipline |
| tarboot | Slot choice, persisted counter transition calculation, security version floor | Writing firmware variables, signature verification, TPM/DICE or recovery entry |
| tarwin-boot | Little-endian TBIB revision 1 encoder, streaming decoder, sorted memory map validation | Physical address ownership, train history validation, CPU entry |
| arch packages | Stage-one user leaf descriptors and walk indices for the ordinary page granule on each ISA | Live page tables, TLB maintenance, trap/interrupt handling or an instruction executed on that ISA |
| tarwin-mm | Physical page arenas, mapping restrictions, A.2 regions, zero/copy/tag restoration, LZ4 blocks, file-cache leases, footprint, purge and jetsam selection | Live page faults, a running reclamation thread, TRFS backing, swap, zstd compaction or a kernel heap |
| tarwin-time | Integer counter conversion, slew and coalescence arithmetic, watchdog thresholds | Clock sampling, timer delivery, wake sources, or a watchdog interrupt |

### Integration constraints

1. A caller of `chooseSlot` must durably write the returned active slot and remaining attempts before entry when `persist` is true. All paths, including recovery, must authenticate and apply the monotonic floor. A candidate version alone cannot advance it.
2. Validate the aligned block's extent and fields before emitting bytes. Decode into private storage, accept only on completion, then validate the train and external physical references against the immutable memory map. Secure Boot and other state bits describe the handoff, not evidence of its origin.
3. `makeArena` consumes eligibility bits only from usable RAM after all permanent and temporary reservations. `takePages` returns physical ownership, not initialized user memory. No page is publishable without initialization and the gated page-table writer.
4. Descriptors have no privileged side effect. Only the authorized writer may install them and must perform architecture-specific synchronization and invalidation. Unsupported translation formats fail closed.
5. TRFS implements the `FilePager` lease on its unified file-cache frame. Pin through installation; release only after teardown and invalidation. These leases do not authorize executable mappings. Anonymous reclaim stores raw LZ4 blocks including packed allocation tags; do not evict on failure or unless storing the block saves memory. Restore into an unpublished frame and discard partial output on any error.

### Pending gates

The released driver has no kernel-profile TIR output. In Swift KLF, `KLFKira/KiraSyntax.swift` explicitly reports lexing and parsing as unsupported. Do not link a KIR host executable, general std, Linux kernel or foreign assembly as a substitute. Boot hardware discovery, freestanding linking, firmware services, kernel entry and the end-to-end §34 suites remain outstanding. No QEMU boot, three-ISA kernel execution, reference hardware, canonical TRFS verification or ten-run same-device Linux comparison has been verified here.
