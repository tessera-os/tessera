# VHE host exception probe

On a Mac with QEMU and the Swift 6.3.3 bare-metal toolchain, set
`EMBEDDED_SWIFTC` to its compiler and run `bash run.sh`. The bounded,
firmware-independent diagnostic starts one AArch64 CPU at EL2, enables
VHE and a 16 KiB EL2/0 translation regime, and installs the host vector at
VBAR_EL2. It never installs an EL0 entry point or dispatches a user call.

The guest reads two words with unprivileged LDTR. A second copy starts in
the last word of that page and faults at the guard. A third read faults on
a privileged-only leaf. The current-EL handler recovers only aborts on the
exact unprivileged access instruction, checking its direction. The Embedded
Swift caller checks that no partial input survives. It round-trips two
words through STTR to a writable user page, rejects read-only, missing and
privileged output, and checks the original read-only bytes. A split output
fault returns failure; completed stores are not transactional.

The boot CPU then runs on a separate upper-half TTBR1 built by the Swift
page-table writer. Its code, exception vector, guarded 32 KiB stack and
private context stay mapped while it installs two finished TTBR0 roots
with the same VA and different frames. It rejects switching from low code
or with a mismatched host root, reads the distinct values across the TLB
invalidation, checks the old identity map and stack guard are absent, and
recovers another store fault on its high-half stack. These are data-only
user roots, not live processes. ASID reuse and SMP shootdown are not tested.

The probe prints the CPU's GCS, S1PIE and TCRX feature nibbles. With
all three at version 1, a second guest enables permission indirection
before enabling its MMU. It checks that the host refuses a direct-permission
root without changing TTBR0. On a private test page with EL0 GCS permission,
the CPU completes a GCSSTTR, rejects an ordinary STTR, and reads back the
first word unchanged. Both instructions run at EL2 with EL0 access checks;
no EL0 instructions run, and no thread's guarded stack is installed.

The lower-EL synchronous slot uses a separate private frame and requires a
kernel-owned dispatcher. This test does **not** exercise that slot, any
return to EL0, signed user code, process keys, GCS call/return, MTE tags, or interrupts.
