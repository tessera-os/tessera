# UEFI firmware interop

Build a disposable PE32+ diagnostic, start it from the removable-media path in QEMU's EDK II firmware, validate live table CRCs, get and normalize the map, then exit boot services using its key. The app issues runtime `ResetSystem(EfiResetShutdown)` only after successful exit and finding both usable memory and runtime descriptors. The runner requires the entry marker and a QMP guest-shutdown event; returning to firmware, hanging and host termination do not pass.

Run on macOS with the Swift **swift.org 6.3.3 release toolchain**, QEMU with its EDK II firmware, and (for RV64) TianoCore **edk2-stable202408** BaseTools. For the last prerequisite, build `make -C BaseTools/Source/C Common GenFw` in the EDK II checkout (on Xcode 27 use `BUILD_OPTFLAGS="-O2 -Wno-macro-redefined"` for the host-side converter). No EDK II code is linked into the diagnostic.

    export EMBEDDED_SWIFTC=/path/to/swift.xctoolchain/usr/bin/swiftc
    export QEMU_FIRMWARE="$(brew --prefix qemu)/share/qemu"
    export EDK_BASETOOLS=/path/to/edk2/BaseTools
    bash run.sh

Pass a subset of `aarch64 x86_64 riscv64` as arguments for a targeted run. All PE files, writable NVRAM copies and logs are temporary. No persistent guest state, signed release image or host firmware is modified.

This calls firmware on emulated CPUs. It does **not** authenticate firmware or boot sets, establish CPU admission, produce kernel-profile TIR, or enter the Tarwin kernel. The Swift/LLVM diagnostic link (including the x64 PE call ABI and the RV64 EDK II image converter) is not release build wiring.
