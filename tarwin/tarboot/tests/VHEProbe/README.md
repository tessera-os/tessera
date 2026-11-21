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

The lower-EL synchronous slot uses a separate private frame and requires a
kernel-owned dispatcher. This test does **not** exercise that slot, any
return to EL0, signed user code, process keys, GCS, MTE tags, or interrupts.
