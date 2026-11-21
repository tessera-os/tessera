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

On the high host stack the import signer rejects a mismatched TTBR1 or
disabled instruction-address authentication. With a public test IA pair
it produces the same PAC as the CPU's reference calculation, restores both
halves of a distinct host IA key, and clears the key-bearing registers.
Only the caller's verified target and storage modifier belong here; no
process key is generated and the probe never branches to the target.

The probe prints the CPU's GCS, S1PIE and TCRX feature nibbles. With
all three at version 1, a second guest enables the W1 permission banks
before enabling its MMU. It rejects a direct user root, then installs a
private root built for those banks. On a GCS page between two unmapped
guards it completes a GCSSTTR, rejects an ordinary STTR and reads the
original word. A sealed RELRO page is readable but not writable, while
an adjacent data page still accepts stores. A third guest with a
different PIRE0 refuses the same root without changing TTBR0.

Only the indirect layout maps the staged user's shadow pages as GCS.
The upper layout supports kernel RX and RW, and rejects ordinary kernel
RO rather than treating it as RW. On the matching root the test writes
the checked first-thread pointer and mode to GCSPR_EL0 and GCSCRE0_EL1,
reads them back, and restores both old registers. No real thread runs:
the test does not execute a user call or return, or switch supervisor GCS.

The baseline guest then feeds the vector's post-dispatch continuation a
stop action on a synthetic private frame. The checked upper root maps two
physically disjoint, guarded 32 KiB stacks. The stop handler confirms it
is running on the scheduler stack with the same TTBR1, interrupts masked
and no outgoing frame chain. This is not a Process.exit syscall or a
scheduler teardown: no exiting process exists in this guest.
The current handoff refuses active EL2 GCS rather than changing SP alone
while leaving the supervisor control stack attached to the outgoing thread.

The lower-EL synchronous slot uses a separate private frame and requires a
kernel-owned dispatcher. This test does **not** exercise that slot, any
return to EL0, signed user code, process keys, GCS call/return, MTE tags, or interrupts.
