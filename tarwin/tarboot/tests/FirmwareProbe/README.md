# UEFI firmware interop

Before firmware exit, the diagnostic opens a raw TIRA test archive on its own EFI System Partition using the loaded-image and simple-file-system protocols. It rejects a too-small destination, reopens the file read-only, checks the member’s BLAKE3 digest, and inspects the ELF for the current architecture. This unsigned test fixture is never mapped or executed.

Build a disposable PE32+ diagnostic and start it from the removable-media path in QEMU's EDK II firmware. It validates table CRCs, reserves loader pages, and exits boot services with the key for the final validated map. After exit it checks the reservation against that map, allocates a Tarwin physical page inside it, writes and reads back the whole page, releases it and rejects a second free.

Two synthetic corrected-error reports on that page cross a test threshold;
the next allocation must use a different frame. For an x64 bank-level test,
run `TARBOOT_TEST_MCA=1 bash run.sh x86_64`. On the pinned one-CPU Intel
TCG profile the host injects two corrected reports for the guest's page.
The guest polls bank 4, checks the physical address and error type, counts
each report before clearing it, and excludes the frame after release.
`TARBOOT_TEST_MCA=wide` injects an address range spanning multiple pages:
the guest must leave the report in the bank and not charge any one page.
No uncorrectable exception, ECC hardware or process termination is tested.

On x64, run with `TARBOOT_TEST_Q35_GENID=present` and `=absent`.
After firmware exit the same guest walks the RSDP and XSDT, requires
one VMGENID SSDT with the q35 AML layout, and reads the GUID only from
the firmware-relocated, write-back ACPI NVS page. The runner compares
the sample against a fresh host GUID. Stock QEMU discovery does not
establish that an internal snapshot load rotates the ID.

On each architecture, the post-exit probe compresses two different page
patterns into one reserved RAM page, frees and overwrites the source frames,
then restores both into a different frame. Discarding the first block
compacts the segment without invalidating the second block's handle.
These are explicit restore calls, not hardware page faults; hosted tests
also round-trip packed allocation tags at both supported page sizes.

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
guard page, including an address-diversified import signed and authenticated
with a disposable, public fixture IA key (original key restored, no branch).
It uses a formerly writable RELRO page sealed in the
unpublished root: its frame still resolves on read, but writes fault
at level 3. It issues AT S1E1R/W for code and stack in a separate upper-half
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

Add `TARBOOT_TEST_GENERATION=1 TARBOOT_TEST_RNG=1` to the FIFO run below to
check the missing-generation fallback. After physical TBIB readback, the
guest scans QEMU virt's fw_cfg directory, reads a fresh 32-byte sample
from swtpm and checks that kernel RNG initialization refuses the absent
generation. The host requires the post-exit serial marker. This negative
probe does not supply an epoch, an ASLR draw or permission to launch W1.

### Detached W1 evidence after EFI exit (debug QEMU only)

Add `TARBOOT_TEST_W1_EVIDENCE=1` to the generation/FIFO test. Before EFI
exit the firmware adapter reads an inert detached envelope from `\BOOT.SIG`
on its own volume. With independent authority absent it returns no kernel.
For an authenticated debug installation, pass the full boot and system TQE1
pins, trusted policy and historical train SDK contract to `firmwareKernel`.
Only the kernel borrowed from the four-member verdict can be installed;
do not hand a verified flag to the next stage or fall back to W0. After EFI
exit the guest rejects the wrong archive PA, then copies the exact bytes of
an inert fw_cfg file once, without overwriting the adjacent sentinel. In
the absence of independent trust inputs, verification refuses it. No image
is staged and this mode never enters a process.

For a provisioned debug launcher the transport is
`-fw_cfg name=opt/org.tessera/tarwin/w1.sig,file=BOOT.SIG`.
This carries only the detached TSG1; it does not carry keys, pins, policy,
SDK, a pointer or a verified bit. Keep the original TBIB archive pinned and
immutable, with no DMA aliases. Copy into private storage, supply separately
installed trust inputs and verify the snapshot with `authorizeQEMUStage1`
before staging. A successful copy is not authorization. The W0 kernel
self-test does not currently call this launcher.

### Debug VMGenID restore

Stock QEMU 11.1.3 does not register VMGenID on ARM virt. The optional
host-side test patch in this directory enables the upstream device and ACPI
linker on virt and adds an opt-in property to generate a fresh GUID from
the host CSPRNG at realization and on VMState load. It is not upstream and
does not certify an arbitrary hypervisor. Only use this single-vCPU, stopped
snapshot profile; do not accept a boot-set flag as management authorization.
The guest polls the page; it does not rely on a VMGenID IRQ.

### Reserved-copy W1 gate (AArch64 debug only)

Use the fixed, single-CPU cold profile below with its checked emulator, EDK II
and a fresh swtpm. The trusted test launcher owns the EFI image, its public
enrollments and signed SDK receipt, RTC, TPM path and all emulated devices.
No passthrough, other submitters, snapshots, migration or hotplug. This does
not protect an EFI image on attacker-controlled media or prove physical DMA
isolation before exit. Do not transfer without an independent protected launcher.

Unlike the unsigned diagnostic, W1 builds the verifier before copying either
input onto the ESP. The EFI image contains no test-generated archive or
configuration digests. Its replay requires the firmware exit-success event
after the two measured records; the expected digests come from the retained
bytes, never the host that supplied the archive.

Set these in addition to the usual Embedded Swift and firmware paths:

```sh
export TARBOOT_TEST_FIXED_GENID=1 TARBOOT_TEST_FIXED_RNG=1 TARBOOT_TEST_COLD_FENCE=1
export TARBOOT_TEST_RNG=1 TARBOOT_TEST_W1_EVIDENCE=1 TARBOOT_TEST_TPM=1 TARBOOT_TEST_FIFO=1
export TARBOOT_TEST_KERNEL_INTAKE=1 TARBOOT_ENTER_W1_INTAKE=1 TARBOOT_TEST_CPU=1 TARBOOT_TEST_FLOOR=1
export TARBOOT_TEST_STAGE0_ARCHIVE=/path/to/TARWIN.TIR TARBOOT_W1_SIGNATURE=/path/to/TARWIN.SIG
export TARBOOT_W1_INSTALL=/path/to/independent-public-installation
# Set TARBOOT_W1_BOOT_SHA256 and TARBOOT_W1_SYSTEM_SHA256 to the trusted enrollment pins,
# not hashes learned from the archive or the ESP.
export TARBOOT_TEST_W1_GATE_ONLY=1
bash run.sh aarch64
TARBOOT_TEST_W1_CHANGED_COPY=1 bash run.sh aarch64
TARBOOT_TEST_W1_CHANGED_ENVELOPE=1 bash run.sh aarch64
```

The default stops **before kernel installation**. The EFI application verifies
and measures the archive and raw boot.json once, copies the archive and
detached envelope, then exits. After acknowledged DMA exclusion it checks both
fresh hashes against the log (including final events) and both replayed bank
values in one TPM read, then independently authorizes the frozen set. The
negative test changes one byte in the retained archive, never the input file;
it must stop at measurement, not at signature verification. Only this fixed
debug profile dedicates PCRs 8 and 9 exclusively to the selected set.

The envelope control keeps the ESP input intact and changes the same byte
in both post-exit signature copies. The transport and PCR comparisons must
pass, then final signature authorization must refuse. This control cannot be
built into a transfer-enabled image.

The gate's success marker is not a kernel-entry witness. A separately
authorized debug transfer requires the kernel-only reverification marker
after the transfer marker; a PCR 10 result is later pre-init evidence, not EL0.

The **debug-only fixed-ID** test is a separate cold launch, not an Arm
generation device. Apply `qemu-11.1.3-no-migration.patch` to QEMU 11.1.3,
rebuild, and put the resulting emulator first on PATH. With the usual
firmware and Embedded toolchain variables set, run
`TARBOOT_TEST_RNG=1 TARBOOT_TEST_FIXED_GENID=1 bash run.sh aarch64`.
Stock QEMU does not implement this flag and the runner must refuse it.
The runner first checks that the same binary refuses incoming and outgoing
migration and snapshot save/load on a disposable control VM. The actual
guest uses raw drives, no saved state, no savevm, and a new UUID per launch.
After EFI exit the debug TBIB reader must see exactly that UUID, and the
ordinary reader must reject the entire block. This is not entropy, a signed
process, a live generation signal or authorization for certified entry.

To check the execution owner's fixed-ID RNG, add `TARBOOT_TEST_FIXED_RNG=1
TARBOOT_TEST_TPM=1 TARBOOT_TEST_FIFO=1`. This build needs
`FixedDebugRandomLaunch` from TarwinKernelRandom. The guest uses a fresh
post-exit TPM2_GetRandom result; only the verified fixed-ID source can draw.
For the complete cold refusal test also set `TARBOOT_TEST_COLD_FENCE=1
TARBOOT_TEST_W1_EVIDENCE=1`. The fence runs before opening the fixed launch
or copying the detached signature. A third PCI endpoint
(`TARBOOT_TEST_EXTRA_PCI=1`) must block both. No test pins authorize an image.

For **x64 q35 ACPI discovery**, run the stock x86_64 probe with
`TARBOOT_TEST_Q35_GENID=present`, then `absent`. The former compares live
page bytes with the host-configured GUID; the latter omits the device.
Neither checks rotation on restore.

To reproduce the rotating Arm device, apply `qemu-11.1.3-virt-vmgenid.patch` with `patch -p1` to
QEMU 11.1.3 (release tar.xz SHA256
`5a8289c7940dc77d3873c81a6c29ba3afe1446fc9d36e77fa1658cdbecb84b22`).
Configure with `--target-list=aarch64-softmmu --enable-tcg --disable-docs`,
build with ninja and prepend the build directory to PATH. Add
`TARBOOT_TEST_RESTORE=1` to the generation/FIFO test above. With the
512 MiB virt-11.1 TCG fixture and edk2-aarch64-code.fd (SHA-256
`47765fe344818cbc464b1c14ae658fb4b854f5c2ceffa982411731eb4865594d`),
both sides independently pin the 4 KiB ACPI NVS page at 0x5c740000,
slot +40. If firmware allocates another page, discovery or restore must
fail; never derive a new destination pin from guest or snapshot bytes.

QMP stops the vCPU before saving to disposable qcow2. The host device
checks the full migrated slot against the destination-only pin, resolves
the complete page to its canonical offset in machine RAM, and writes just
the new GUID there. Management compares the live device GUID with those
16 guest bytes before save and again while paused after load. Only then
does it resume this diagnostic. Repeat with `TARBOOT_TEST_WRONG_PAGE=1`
to use a different destination pin: the load must fail before rotation
and the vCPU must remain stopped. After a checked initial draw the guest must
see the live NVS GUID change, reject both the new epoch and the latched
old one, then accept a fresh TPM reseed at the new epoch. Before the snapshot,
a disposable process borrows its IA pair, starts a thread and borrows all
five pairs without installing them. After restore the otherwise runnable
thread must be refused before the key callback, even when presented with
the original epoch again. No entropy or key material is printed. This is not a production launch or an SMP,
postcopy, ACPI-interrupt or cross-host migration test. This fixture still
needs fw_cfg DMA for firmware discovery. It does not drain other devices,
prove that protected pages have no DMA aliases, or authorize W1 entry.

For the separate no-fw_cfg-DMA fixture, add `TARBOOT_TEST_RO_GENID=1` to
the restore run. The same QEMU patch supplies a non-hotpluggable VMGENID
subclass on virt-11.1. It omits the ACPI table, GUID/address blobs, IRQ and
RAM update hook. A one-byte fw_cfg file `etc/tarwin/vmgenid-ro` advertises
register ABI 1, not an address or generation. Without it this profile
refuses before probing MMIO. The live value is only in a read-only 16 KiB I/O region at
0x090d0000, outside RAM and the platform bus. Aligned 64-bit reads at +0,
+8, +16 and +24 return the ABI magic, destination version and GUID words.
Two matching nonzero versions bracket each sample. Neither the GUID nor
the version is migrated. Reset and paused post-load rotate on the host;
a running restore is not supported. The guest refuses other fw_cfg feature
bits, the old ACPI inventory, a wrong magic, all-zero GUID or torn samples.

This headless fixture uses SMMUv3 with default bus bypass off, no MSI, and
modern-only ACCESS_PLATFORM disk and RNG endpoints. The guest and QMP both
read the actual device's GUID across save/load. This tests generation, not
DMA containment: a previously established cold fence cannot survive restore.

**Cold post-EFI W1 verification (negative authority).** Use the read-only
generation fixture above, replace `TARBOOT_TEST_RESTORE=1` with
`TARBOOT_TEST_COLD_FENCE=1`, and enable `TARBOOT_TEST_W1_EVIDENCE=1`.
This pins `highmem-mmio=off`, leaving high ECAM enabled, so EDK2 assigns
both modern endpoints’ BAR4s inside the bounded low PCI window. A single
CPU reserves two contiguous loader-owned WB pages, exits EFI and calls
the device provider before the post-exit verifier can copy a signature.
After the reset, bus-master readback and SMMU synchronization, signature
transport succeeds but independent authority is absent: no W1 set or
entry. Repeat with `TARBOOT_TEST_EXTRA_PCI=1` to add an unexpected
virtio balloon: the launcher must refuse without modifying the copy buffer.
Register dumps on refusal are public PCI configuration/GICR/SMMU state.
Do not enable hotplug or restore in this cold machine. The restore probe
above only tests generation and never calls the cold verifier. This is a
post-exit verifier in the EFI diagnostic, not a signed kernel launch.

Optional `TARBOOT_TEST_HIGH_PCI=1` pins the 512 GiB high PCI window.
Before the first endpoint reset the guest requires both assigned 16 KiB
BAR4s in that window and checks each 4 KiB page with AT S1E2W: it must
be writable Device memory at the same physical address. A failed walk or
cacheable alias is not a usable mapping. `TARBOOT_TEST_HIGH_PCI=wrong-window`
runs that high-only check against a low-only machine; no signature may be
copied. The default launcher still uses only low MMIO.

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
