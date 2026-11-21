# VHE host exception probe

On a Mac with QEMU and the Swift 6.3.3 bare-metal toolchain, set
`EMBEDDED_SWIFTC` to its compiler and run `bash run.sh`. The bounded,
firmware-independent diagnostic starts one AArch64 CPU at EL2, enables
VHE and a 16 KiB EL2/0 translation regime, and installs the host vector at
VBAR_EL2. Only the separate guarded-interval guest executes EL0.

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

### Observed EL0 interval (QEMU 11.1.3, single CPU)

The additional guarded-interval guest enters a dedicated diagnostic RX
page, **not a signed image**. The runner checks QEMU's exception trace for
the first EL2-to-EL0 return at the exact test entry, two returns in total,
and two EL0-to-EL2 SVCs. No key register dump is needed. The guest rejects
disabled IA, a non-EL0 frame, a mismatched host root and a short host stack
before entry. In EL0 it uses the user stack, reads its TLS register,
calls and returns with GCS enabled, and calculates five PACs. Back in EL2 it
checks those results against a separate reference, both halves of every
restored host key, the old TTBR0, the control-stack cursor, and both saved
PCs. The first SVC goes through the Swift private dispatcher with no service
registered. EL0 receives its unavailable status; the second SVC is outside
the allowed instruction interval and is not resumed.

The measured-thread adapter consumes the actual private image tables and
preloaded child frame, measures the original pinned signed init, and uses
the runnable thread's key bank. Only the original library RX interval is
accepted for dispatch. The guest above tests the architectural transition,
not archive enrollment, first entry of signed init, a successful registered
syscall, interrupt handling, SMP or scheduling. W0's independent page and
run-queue self-test does not constitute W1 entry.

With the writer-free QEMU patch from the EFI fixture, set
`TARBOOT_TEST_RO_GENID=1` to sample the same live device after switching
away from the bootstrap identity map. An unpublished guarded TTBR1 maps
only the 16 KiB register aperture at its high address as Device-nGnRnE.
The reader refuses an inactive root, unaligned offsets and addresses
outside the four defined registers. The hardware walk permits EL2 reads,
rejects EL2 writes and EL0 reads, and no longer resolves the old low address.
The guarded-interval guest also checks a fresh versioned sample before
each diagnostic EL0 entry. The measured import and entry APIs accept the
kernel mapping, not a caller-supplied word reader. Neither test logs the
ID or serves as a restore fence or signed process authorization.
