# Stage-0 targets

The AArch64 W0 target note includes the 17 names implied by the full
`aarch64.base` baseline, not just optional extras. The x64 kernel body is
built with `bash kernel-object.sh NEW-BODY.o x86_64`: its 4 KiB page test
uses the Tarwin §6.6 physical handoff in RDI. Stage0Image links a tagged §17.2
entry veneer, the full `x64.v3` feature closure and fixed vscale 2; an
object alone does not prove that a guest CPU satisfies this baseline.

## Build a W0 kernel image

From this directory in a full Cairn checkout on a Mac:

    export EMBEDDED_SWIFTC=/path/to/the/swift.org-mac-toolchain/usr/bin/swiftc
    work=$(mktemp -d)
    bash kernel-object.sh "$work/kernel.o"
    swift run --scratch-path "$work/tools" Stage0Image "$work/kernel.o" "$work/kernel.unsigned.elf"
    bash kernel-object.sh "$work/x64.o" x86_64
    swift run --scratch-path "$work/tools" Stage0Image "$work/x64.o" "$work/x64.unsigned.elf"
    swift test --scratch-path "$work/tools"

The cross compiler identifies itself as Apple Swift 6.3.3 (swift-6.3.3-RELEASE).
Use its matching bare-metal modules, clang and LLD. Xcode 26's bundled swiftc
lacks those modules; do not mix serialized modules from different releases.
The host packager uses regular Swift. The freestanding image uses Embedded
Swift with no allocations, no hosted runtime, and general-purpose registers.
This is the stage-0 compiler exception, **not** evidence that the self-hosted
Swift compiler generated or verified kernel-profile TIR.

The hosted bridge imports live AArch64 or x64 ET_REL code, constants and supported
local relocations into A12's ObjectFile model. Unknown allocated sections,
writable data, external references and unsupported relocations fail the build.
A12 applies the link relocations and writes the Tarwin ET_DYN; the loader's
unsigned interoperability check validates its build ID, notes and directory.
The output has no signature, grants or finalizer note. Its profile/kind are
kernel/kernel, target aarch64.base or x64.v3, build and expiry both 26.11.1. This
short-lived debug candidate must not enter a release boot.

On AArch64 the separate kernel entry `tarwin_start` expects the physical TBIB in x0,
a private boot stack and the §6.6 EL2 entry state. For this W0
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

### Assemble the restricted W1 debug candidate

    swift run Stage0Image w1-bootset KERNEL.elf INIT.elf LIBTESSERA.elf NEW-W1.TIR

Supply the three native-signed images, then send the output for detached
signing. The four raw members are `LibTessera`, `boot.json`, `kernel`, and
`tessera.init`, in bytewise name order. Paths passed on the command line
do not set member names or establish any executable identity. The packer
neither verifies signatures nor makes an image launchable. W0 remains a
two-member archive; the W1 guest needs separate role and RX-range checks
and the kernel must measure the authorized init in PCR 10 before launch.

### Assemble the opt-in system-root debug candidate

    swift run Stage0Image w1-system-root-bootset KERNEL.elf INIT.elf LIBTESSERA.elf ROOT.bin NEW-ROOT.TIR

This distinct profile adds `system.trfs.root` to the four W1 members. Supply
the 32 raw SHA-256 bytes of the nonempty TRFS metadata head, not ASCII hex,
a sector address, or a whole-disk hash. The full five-member archive needs
its own detached signature. The mount must compare the digest returned by
the system-root verifier with the independently read disk head, measure the
match, then mount read-only. Packing bytes alone authorizes neither disk nor
process. The ordinary W0 and W1 archives are unchanged.

### Compile the AArch64 cold intake kernel (unsigned)

Set `EMBEDDED_SWIFTC` to Embedded Swift 6.3.3. Supply the independent public
installation used by the fixed debug firmware and the two trusted enrollment
SHA-256 pins, not data read from the ESP:

    bash w1-intake-object.sh NEW-INTAKE.o PUBLIC-INSTALL BOOT-PIN SYSTEM-PIN

The output is an allocation-free relocatable object, not a signed image.
It checks fence continuity and reauthorizes the input on entry, stages the
process and library in an unpublished private address space, and measures
the authorized init before stopping. It never installs a live process root,
switches a thread or enters EL0. Building the object does not test any of
these operations in a guest or change an existing signed fixture.

To check the MMU-off memory routines on the host:

    swiftc -O Kernel/ColdMemory.swift Tests/ColdMemoryCheck.swift -o /tmp/cold-memory-check
    /tmp/cold-memory-check
