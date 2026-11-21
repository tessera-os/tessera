# AArch64 stage-2 execution diagnostic

From this directory, run `sh run.sh` on the Mac with the Swift.org 6.3.3
toolchain and `qemu-system-aarch64` on PATH. Override `SWIFT_TOOLCHAIN` with
the toolchain's bin directory if needed. The probe compiles the package
sources and call index with Embedded Swift and the no-allocation check,
then boots its own single-core ELF on QEMU TCG, not the Tarwin boot set.

The guest runs in EL1h with stage 1 disabled and a nonidentity, 16 KiB
stage-2 translation. The VHE EL2 monitor uses the package's extent lifecycle
and creator-thread run path. A PASS on the host-only UART requires:

1. A guest write reaching its pinned host frame, followed by HVC 0x42
   with CurrentEL=EL1 in the saved GPR bank.
2. The host detaching, invalidating the VMID, and remapping read-only;
   the retried guest write takes a level-3 permission fault without changing data.
3. After detach and invalidation, a guest read takes a level-3 translation
   fault with the expected fault IPA.
4. A halfword store and signed byte load at a separately registered MMIO
   aperture return typed exits. The guest observes the sign-extended result.
5. After a writable, nonexecutable remap, an indirect branch to the data IPA
   takes a level-3 instruction permission fault.

Observed with QEMU 11.1.3 on an arm64 Mac. One trusted instruction fixture,
fixed EL1 control state, private integer bank, no guest FP/SIMD or live devices,
and one VMID: **not a production context switch or an OS guest boot**.
The linker owns the test frames; production must obtain them from the VM/pin
owner, quiesce every vCPU, implement global shootdown/VMID reuse, and bind
the verified all-three architecture variants. The [shared harness](../StageTwoHarness/README.md)
runs separate x64 and RV64 guests. None of the three establishes physical timing,
KLF kernel-profile compliance or release acceptance.
