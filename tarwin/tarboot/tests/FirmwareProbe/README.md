# UEFI firmware interop

Before firmware exit, the diagnostic opens a raw TIRA test archive on its own EFI System Partition using the loaded-image and simple-file-system protocols. It rejects a too-small destination, reopens the file read-only, checks the member’s BLAKE3 digest, and inspects the ELF for the current architecture. This unsigned test fixture is never mapped or executed.

Build a disposable PE32+ diagnostic and start it from the removable-media path in QEMU's EDK II firmware. It validates table CRCs, reserves loader pages, and exits boot services with the key for the final validated map. After exit it checks the reservation against that map, allocates a Tarwin physical page inside it, writes and reads back the whole page, releases it and rejects a second free.

With one boot CPU, the probe then starts the bootstrap scheduler and advances an explicit test counter through tickless operation, contention, slice expiry, blocking and idle. The scheduler and counter conversion are the real modules; the context IDs and clock samples are test inputs. No hardware timer interrupt or machine context switch is exercised. Only after both checks pass does the guest issue runtime `ResetSystem(EfiResetShutdown)`. The runner requires both the entry marker and a QMP guest-shutdown event.

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

With `swtpm` installed, run `TARBOOT_TEST_TPM=1 bash run.sh aarch64 x86_64`. This starts a fresh software TPM for each guest. Before exit, the probe reads SHA-256 PCRs 8 and 9, uses UEFI TCG2 to hash, log and extend the archive and a fixed canonical config, then reads both PCRs again. The host independently hashes each payload and checks the resulting PCR against the previous PCR and that hash. A partially logged/extended pair is terminal; the guest never retries or treats a skipped measurement as success. This verifies PCR values, not the complete firmware event log or signer provenance. The bundled RV64 EDK II firmware returns `EFI_NOT_FOUND` for TCG2 with a TPM device attached, so measured boot on RV64 is **not verified**.

This calls firmware on emulated CPUs. It does **not** authenticate firmware or boot sets, establish CPU admission, produce kernel-profile TIR, or enter the Tarwin kernel. The Swift/LLVM diagnostic link (including the x64 PE call ABI and the RV64 EDK II image converter) is not release build wiring.
