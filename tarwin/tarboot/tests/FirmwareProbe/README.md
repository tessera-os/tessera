# UEFI firmware interop

Before firmware exit, the diagnostic opens a raw TIRA test archive on its own EFI System Partition using the loaded-image and simple-file-system protocols. It rejects a too-small destination, reopens the file read-only, checks the member’s BLAKE3 digest, and inspects the ELF for the current architecture. This unsigned test fixture is never mapped or executed.

Build a disposable PE32+ diagnostic and start it from the removable-media path in QEMU's EDK II firmware. It validates table CRCs, reserves loader pages, and exits boot services with the key for the final validated map. After exit it checks the reservation against that map, allocates a Tarwin physical page inside it, writes and reads back the whole page, releases it and rejects a second free.

The diagnostic dedicates a page to two type-isolated small-object slabs. An
exhausted slab cannot use its neighbour or reclaim a quarantined slot. After
explicit release of a test quarantine batch the slot is zero on reuse. The
page remains reserved until shutdown. These non-MTE QEMU configurations do not
exercise synchronous tagging, timed quarantine, job charging, or per-CPU refill.

With one boot CPU, the probe then starts the bootstrap scheduler and advances an explicit test counter through tickless operation, contention, slice expiry, blocking and idle. The scheduler and counter conversion are the real modules; the context IDs and clock samples are test inputs. No hardware timer interrupt or machine context switch is exercised. Only after all checks pass does the guest issue runtime `ResetSystem(EfiResetShutdown)`. The runner requires both the entry marker and a QMP guest-shutdown event.

Run on macOS with the Swift **swift.org 6.3.3 release toolchain**, QEMU with its EDK II firmware, and (for RV64) TianoCore **edk2-stable202408** BaseTools. For the last prerequisite, build `make -C BaseTools/Source/C Common GenFw` in the EDK II checkout (on Xcode 27 use `BUILD_OPTFLAGS="-O2 -Wno-macro-redefined"` for the host-side converter). No EDK II code is linked into the diagnostic.

    export EMBEDDED_SWIFTC=/path/to/swift.xctoolchain/usr/bin/swiftc
    export QEMU_FIRMWARE="$(brew --prefix qemu)/share/qemu"
    export EDK_BASETOOLS=/path/to/edk2/BaseTools
    bash run.sh

Pass a subset of `aarch64 x86_64 riscv64` as arguments for a targeted run. All PE files, writable NVRAM copies and logs are temporary. No persistent guest state, signed release image or host firmware is modified.

`TARBOOT_TEST_DISPLAY=1 bash run.sh` tests the debug-only framebuffer console on
all three architectures. Before exit, firmware supplies a linear GOP mode;
after exit the diagnostic writes “TARWIN TEST” directly to its mapped aperture,
without calling a firmware output service. QEMU retains the guest display at
shutdown and the host checks every glyph and background pixel in a QMP PPM
screendump. To keep full-size evidence, set `TARBOOT_TEST_SCANOUT_DIR` to an
existing empty directory. This exercises emulated scanout, not kernel entry
or a hardware display driver.

`TARBOOT_TEST_RNG=1 bash run.sh` attaches a host-backed virtio entropy device
and requests a 64-byte seed with EFI RNG's RAW algorithm. Placement draws use
separate default RNG words. The virtual window must fit all 2^18 aligned starts;
the physical draw weights validated writable, write-back conventional descriptors
by the number of fitting starts, rejecting modulo bias and unavailable candidates.
Only successful EFI AllocateAddress acquires the exact physical extent. The
probe rechecks it in the final map and exercises it after exit; no seed or
address is logged. This does not map a kernel at the chosen VA or establish the
entropy quality of any physical source.

The probe snapshots ACPI 2.0 and FDT directory entries before exit. After exit
it checks the RSDP and XSDT lengths and checksums, and walks the supplied FDT
to its final token. Reads are bounded by the final firmware descriptors. These
checks do not establish ACPI 6.4 platform conformance or interpret child SDTs.

The RNG-enabled run builds an Appendix A.1 block in its own EFI reservation,
followed by the serialized memory map. Only the exact boot-set and boot-info
reservations are retyped, including when firmware coalesces adjacent loader
allocations. Boot-services pages remain reserved; no consumer may infer
reclamation authority from this map. The reader checks all 32-byte records and
coverage of the actual TBIB, map and archive before returning the decoded block.
GOP is included when requested. The image bases name a test reservation, not
executable code. The train and slot are fixture values. The block reports a debug
image, not Secure Boot. With TPM enabled it includes the captured event log.

The measured diagnostic requests the crypto-agile log with GetEventLog, refuses
firmware-reported truncation, and copies through the *end* of the reported last
record. It recognizes the SHA-1, SHA-256, SHA-384, SHA-512 and SM3-256 bank
sizes and requires SHA-256. After exit it appends new Event2 records from the
final-events table, never duplicating the prefix from an earlier firmware reader.
The guest checks the archive and configuration SHA-256 digests against the host
fixture and requires the successful exit event. This is log framing and selected
event verification, not replay or attestation of the rest of the firmware chain.

With `swtpm` installed, run `TARBOOT_TEST_TPM=1 bash run.sh aarch64 x86_64`. This starts a fresh software TPM for each guest. Before exit, the probe reads SHA-256 PCRs 8 and 9, uses UEFI TCG2 to hash, log and extend the archive and a fixed canonical config, then reads both PCRs again. The host independently hashes each payload and checks the resulting PCR against the previous PCR and that hash. A partially logged/extended pair is terminal; the guest never retries or treats a skipped measurement as success. This verifies PCR values, not the complete firmware event log or signer provenance. The bundled RV64 EDK II firmware returns `EFI_NOT_FOUND` for TCG2 with a TPM device attached, so measured boot on RV64 is **not verified**.

This calls firmware on emulated CPUs. It does **not** authenticate firmware or boot sets, establish CPU admission, produce kernel-profile TIR, or enter the Tarwin kernel. The Swift/LLVM diagnostic link (including the x64 PE call ABI and the RV64 EDK II image converter) is not release build wiring.
