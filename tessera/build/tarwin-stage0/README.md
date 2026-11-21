# Stage-0 aarch64 W0 kernel image

From this directory in a full Cairn checkout on a Mac:

    export EMBEDDED_SWIFTC=/path/to/the/swift.org-mac-toolchain/usr/bin/swiftc
    work=$(mktemp -d)
    bash kernel-object.sh "$work/kernel.o"
    swift run --scratch-path "$work/tools" Stage0Image "$work/kernel.o" "$work/kernel.unsigned.elf"
    swift test --scratch-path "$work/tools"

The cross compiler identifies itself as Apple Swift 6.3.3 (swift-6.3.3-RELEASE).
Use its matching bare-metal modules, clang and LLD. Xcode 26's bundled swiftc
lacks those modules; do not mix serialized modules from different releases.
The host packager uses regular Swift. The freestanding image uses Embedded
Swift with no allocations, no hosted runtime, and general-purpose registers.
This is the stage-0 compiler exception, **not** evidence that the self-hosted
Swift compiler generated or verified kernel-profile TIR.

The hosted bridge imports live AArch64 ET_REL code, constants and supported
local relocations into A12's ObjectFile model. Unknown allocated sections,
writable data, external references and unsupported relocations fail the build.
A12 applies the link relocations and writes the Tarwin ET_DYN; the loader's
unsigned interoperability check validates its build ID, notes and directory.
The output has no signature, grants or finalizer note. Its profile/kind are
kernel/kernel, target aarch64.base, build and expiry both 26.11.1. This
short-lived debug candidate must not enter a release boot.

The separate kernel entry `tarwin_start` expects the physical TBIB in x0,
a private 32 KiB boot stack, and the §6.6 EL2 entry state. For this W0
composition the producer pins 24 KiB (aligned TBIB followed immediately by
up to 20 KiB of map), protects the image and stack as reserved, and supplies
a verified debug GOP aperture. The single CPU consumes the validated usable
RAM map, takes and tests a 16 KiB page, frees it, exercises the boot CPU queue,
and writes **TARWIN W0 PASS** to the aperture on success. Neither the EFI
diagnostic nor the packager prints that message on the guest's behalf.

**Not launch authority:** Only the signing/loader owner may turn this artifact
into a verified native-image candidate. Tarboot must authorize a signed archive
and member on the very bytes it loads, measure them, and enforce the version
floor. A locally produced digest, ELF note, or test signer embedded in the ELF
is not trust. Packaging and host tests alone are not a boot or timer interrupt.

### Assemble the W0 archive

    swift run --scratch-path "$work/tools" Stage0Image bootset "$work/kernel.unsigned.elf" "$work/BOOT.TIR"

This deterministic TIRA contains two sorted raw members: debug slot-A
`boot.json` with security version 1, and the supplied `kernel`, verbatim.
Each has an uncompressed BLAKE3 digest. After native signing, rerun with the
signed ELF to a new archive path; sign the exact repacked TIRA separately.
This is a W0 fixture, not the full §6.3 boot set.
