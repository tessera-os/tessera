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
checks do not establish ACPI 6.4 platform conformance.

`TARBOOT_TEST_SMP_TABLES=1 bash run.sh` configures four QEMU vCPUs. After
exit the boot CPU enumerates four distinct, enabled hardware IDs from the
checksummed ACPI MADT or (on a system without ACPI) the /cpus subtree. A
supplied but invalid ACPI directory is never replaced with a DT fallback.
This discovers CPUs; it does not start them, test their security features,
configure interrupt routing, or demonstrate SMP scheduling.

The RNG-enabled run builds an Appendix A.1 block in its own EFI reservation,
followed by the serialized memory map. Only the exact boot-set and boot-info
reservations are retyped, including when firmware coalesces adjacent loader
allocations. Boot-services pages remain reserved; no consumer may infer
reclamation authority from this map. The reader checks all 32-byte records and
coverage of the actual TBIB, map and archive before returning the decoded block.
GOP is included when requested. The image bases name a test reservation, not
executable code. The train and slot are fixture values. The block reports a
debug image. Only the signed diagnostic run sets the firmware Secure Boot bit;
with TPM enabled the block also includes the captured event log.

`TARBOOT_TEST_SECURE_FIRMWARE=1 TARBOOT_TEST_RNG=1 bash run.sh x86_64` uses
QEMU's SMM-enabled OVMF secure-code image. In addition to the usual tools it
requires `openssl`, `osslsigncode` and `virt-fw-vars` on PATH (tested with
virt-firmware 25.12 and setuptools 80.9 in a private Python virtualenv).
Three temporary keys enroll PK, KEK and db in a scratch copy of guest VARS;
no host firmware or keychain is used. The first launch must explicitly reject
the unsigned image on the ESP's PCI path without reaching its entry marker.
With fresh, identically enrolled VARS the same PE signed with the db test key
must run, read SecureBoot=1 and SetupMode=0, and shut down successfully.
The bundled OVMF's reported UEFI revision is below the Tarwin 2.9 minimum:
it exercises enforcement but is not an admitted release platform. This test
does not sign the archive, verify Tarwin's release chain, or authorize entry.

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

For the unsigned stage-0 intake control, supply the archive produced by
`Stage0Image bootset` with the unsigned A12 kernel:

    TARBOOT_TEST_STAGE0_ARCHIVE=/absolute/path/to/BOOT.TIR TARBOOT_TEST_TPM=1 TARBOOT_TEST_RNG=1 TARBOOT_TEST_DISPLAY=1 bash run.sh aarch64

The guest reads the archive from the ESP, checks both member digests, parses
the restricted debug config and checks the ELF's unsigned build ID and kernel
profile. The run requires explicit rejection by signed-image preflight.
PCR 9 measures the actual archive member; host replay uses the independently
expected config. Only the EFI diagnostic runs and writes to the display.

With `TARBOOT_TEST_TPM=1 TARBOOT_TEST_FLOOR=1` the Mac harness provisions a
counter in an **empty, disposable swtpm** before QEMU starts. It sends commands
over a private socket pair, not to a host device. Only this fixture uses this
index and the disposable platform hierarchy's empty provisioning password.
Tarboot's read-only API takes the index and expected SHA-256 Name digest from
trusted installation policy, requires a written platform-created counter with
the exact NV public area, and checks both TPM responses. The guest reads the
persisted value and rejects a different Name. A missing or malformed response
is not floor zero. This does not enroll a physical TPM, authenticate a boot
set, or advance the counter after a confirmed install.

### QEMU-only signed W0 admission

Use a separately enrolled disposable signing identity (see the loader's
SignFixture and w0 package). Keep its public TQE1 off the ESP. Supply an
archive with a signed kernel and a matching detached TSG1 from that signer:

    TARBOOT_QEMU_ENROLLMENT=/trusted/qemu.pub TARBOOT_TEST_SIGNATURE=/fixtures/BOOT.SIG \
    TARBOOT_TEST_STAGE0_ARCHIVE=/fixtures/BOOT.TIR TARBOOT_TEST_CPU=1 \
    TARBOOT_TEST_FLOOR=1 TARBOOT_TEST_TPM=1 bash run.sh aarch64

Both signatures over each of the archive and native image are checked **in
the guest**. Only the test loader contains the public enrollment. The guest
reads the TPM floor, EFI RTC (QEMU configured for UTC) and Arm ID registers;
no clock, enrollment, CPU assertion or floor is loaded from the archive.
The accepted kernel view borrows bytes in the same held archive allocation.
Repeat with `TARBOOT_BAD_SIGNATURE=1` to flip one bit on the ESP: the run
requires explicit refusal. This admission diagnostic does not enter the ELF.

`TARBOOT_TEST_CPU=1` enables guest register snapshots. The AArch64
diagnostic requires the 17 named features, current EL2, VHE, 16 KiB granule,
PAN2, GIC system registers and an implemented counter frequency. On aarch64
`TARBOOT_TEST_CPU=refusal` uses Cortex-A72 and requires a negative result.
The x64 CPUID and RV64 SBI snapshots are *not* complete baseline checks.
None of these tests establishes release trust or physical hardware support.

### Enter the separate AArch64 kernel

Add `TARBOOT_ENTER_W0=1 TARBOOT_TEST_DISPLAY=1 TARBOOT_TEST_RNG=1` to
the positive signed invocation above. Use the tagged A12 kernel, with a
16-byte-aligned `tarwin_start`, the physical-TBIB type tag at E−4 and
BTI C at E. This build is for **one QEMU CPU only**. After authorization,
tarboot zeroes its private random image reservation and installs only the
bounded R/RX PT_LOAD spans. The firmware exit map pins the image and a
separate 64 KiB stack. After TBIB readback it cleans image and handoff
ranges, invalidates I-cache, masks DAIF, turns off the EL2 MMU and caches,
switches stacks and branches with x0 = physical TBIB. The signed ELF never
returns. There are no post-exit firmware calls in this path.

The runner compares every pixel of **TARWIN W0 PASS** from QMP scanout
before stopping QEMU. Only the kernel draws that string; the EFI image is
checked not to contain it. Set `TARBOOT_TEST_SCANOUT_DIR` to an existing
empty directory to save the PPM. This is a stage-0 shell-free boot, not an
OS install, SMP test, hardware timer interrupt or certified boot chain.

The tagged 26.11.1 fixture (TIRA SHA-256
`5d952273f606acd408df9dbc9281bb4142f20c4f61a802ed96697bb511cbbab0`)
produced an 800×600 PPM with SHA-256
`dd43b917e984984ed7cd95fc97774489ba1a591b30f43e45a9091dda6d30fbfa`
on independent Mac runs. Both runs rejected a bit flip in the detached
signature. Verification at another time requires a currently valid isolated
enrollment; do not override the firmware clock to keep a fixture valid.

### x64 W0 target refusal

Use the x64 signed archive and detached signature in place of the AArch64
fixtures. Keep the separately provisioned enrollment, TPM and floor settings.
Set `TARBOOT_TEST_CPU=x64-refusal`, leave `TARBOOT_ENTER_W0` unset, and run
`bash run.sh x86_64`. This check expects an **incompatible** TCG `-cpu max`
guest, not a portable assertion that all QEMU versions must fail. It obtains
CPUID in the guest, measures the archive, supplies the failed target check to
the verifier and requires refusal before installation. A matching CPUID alone
would not prove §5.1 supervisor setup, virtualization or working CET.

### AArch64 user and kernel translation probe

`TARBOOT_TEST_TRANSLATION=1 TARBOOT_TEST_CPU=1 bash run.sh aarch64` builds
16 KiB stage-1 tables in a private post-exit reservation. On a single
EL2 CPU the diagnostic issues AT S1E0R/W for lower-half frames and a
guard page, and AT S1E1R/W for code and stack in a separate upper-half
TTBR1 root. EL0 cannot read kernel code or write the kernel stack, and
EL1 cannot write the read-only code or read an unmapped guard. It checks
physical frame addresses and architectural fault status from PAR_EL1,
then restores both roots and the inactive EL1/0 regime. It
never executes an EL0 instruction, activates a process or tests VHE host
context switching. It does not consume a signed W0 archive.

### AArch64 secondary state before CPU bring-up

Add `TARBOOT_TEST_PSCI=1 TARBOOT_TEST_SMP_TABLES=1 TARBOOT_TEST_CPU=1`
to the AArch64 diagnostic. On the four-vCPU QEMU virt machine it requires
a checksum-valid ACPI FADT advertising PSCI over SMC, matches MPIDR_EL1
with a MADT GICC, and queries PSCI_VERSION and AFFINITY_INFO64 at level
zero. The boot CPU must be ON and the other three OFF. This does not
start a secondary CPU or test IPI delivery or scheduling.

### AArch64 post-exit PCR transport

`TARBOOT_TEST_TPM=1 TARBOOT_TEST_FIFO=1 bash run.sh aarch64` binds a single
QEMU virt platform-bus TIS device to disposable swtpm. After ExitBootServices,
TarwinBoot requests locality zero and streams the ESP fixture bytes through
the TPM event sequence. The final command extends PCR 10 and returns each
bank's digest. The probe appends an Event2 record to the reserved copy of
the firmware log, requiring its digest banks to match the Spec ID header.
Through the MMIO FIFO only, it reads the starting SHA-256 PCR (must be zero)
and the result (must match the host replay). Add `TARBOOT_TEST_RNG=1` to
check the new log extent in the physical boot-info handoff. A short, malformed
or timed-out transaction is terminal. This measures test data, not an authorized
init image; it does not discover a production TPM or launch W1. Before
measurement the guest also obtains a 32-byte TPM2_GetRandom sample without
logging its value. This checks transport only, not physical entropy quality,
kernel RNG initialization or snapshot-generation detection.
