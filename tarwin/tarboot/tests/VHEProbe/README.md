# VHE host exception probe

On a Mac with QEMU and the Swift 6.3.3 bare-metal toolchain, set
`EMBEDDED_SWIFTC` to its compiler and run `bash run.sh`. The bounded,
firmware-independent diagnostic starts one AArch64 CPU at EL2, enables
VHE and a 16 KiB EL2/0 translation regime, and installs the host vector at
VBAR_EL2. It never installs an EL0 entry point or dispatches a user call.

The guest reads two words with unprivileged LDTR. A second copy starts in
the last word of that page and faults at the guard. A third read faults on
a privileged-only leaf. The current-EL handler recovers only aborts on the
exact LDTR instruction. The Embedded Swift caller checks both failures and
that no partial words remain; only then does it emit the success marker.

The lower-EL synchronous slot uses a separate private frame and requires a
kernel-owned dispatcher. This test does **not** exercise that slot, any
return to EL0, signed user code, process keys, GCS, MTE tags, or interrupts.
