// Standalone debug-QEMU boot CPU at EL2. Stage the VHE host MMU with RX
// kernel text and private data in the temporary identity map. Relocate to
// TTBR1 and switch between process roots. Only TEST_SLICE executes EL0.
print("""
.section .text.boot,"ax"
.globl _start
_start:
  mrs x0, CurrentEL
  cmp x0, #8
  b.ne failed
  msr daifset, #15
  msr spsel, #1
  ldr x0, =stack_top
  mov sp, x0
  // Report guest-visible features, not a claim that a control stack is
  // installed. W1 cannot use an ordinary writable page as a GCS.
  mrs x2, id_aa64pfr1_el1
  ubfx x2, x2, #44, #4
  mrs x3, S3_0_C0_C7_3 // ID_AA64MMFR3_EL1
  ubfx x4, x3, #8, #4  // S1PIE
  and x3, x3, #15     // TCRX
  adr x1, gcs_features
  bl hex_digit
  mov x2, x4
  bl hex_digit
  mov x2, x3
  bl hex_digit
  adr x1, gcs_report
  mov x0, #4
  hlt #0xf000
  ldr x0, =host_root
  ldr x1, =private_a
  ldr x2, =private_b
  ldr x3, =stack_base
  ldr x4, =context
  ldr x5, =_start
  ldr x6, =sample
  ldr x7, =scheduler_base
  bl tarwin_vhe_build_roots
  #ifdef TEST_HIGH_GENID
  cmp w0, #6
  b.eq genid_absent
  #endif
  cbnz w0, failed
  mov x0, #1
  lsl x0, x0, #34
  orr x0, x0, #(1 << 31)
  orr x0, x0, #(1 << 27)
  msr hcr_el2, x0
  isb
  #ifdef TEST_TIME_PAGE
  mov x0, #2 // VHE: permit only EL0 virtual counter access, not timer control.
  msr cnthctl_el2, x0
  isb
  #endif
  ldr x0, =tarwin_w1_vectors
  msr vbar_el2, x0
  ldr x0, =root
  msr ttbr0_el2, x0
  ldr x0, =host_root
  msr ttbr1_el2, x0
  ldr x0, =0x57510b510
  msr tcr_el2, x0
  mov x0, #255
  msr mair_el2, x0
  #ifdef TEST_GCS
  mrs x2, id_aa64pfr1_el1
  ubfx x2, x2, #44, #4
  cmp x2, #1
  b.ne failed
  mrs x3, S3_0_C0_C7_3
  ubfx x4, x3, #8, #4
  cmp x4, #1
  b.ne failed
  and x4, x3, #15
  cmp x4, #1
  b.ne failed
  // The boot identity aliases only contain kernel RX and RW pages.
  ldr x0, =0x000c080a00000000
  msr S3_4_C10_C2_3, x0
  #ifdef TEST_WRONG_BANK
  mov x0, #0x0900000000000000 // deny more than the root expects
  #else
  ldr x0, =0x89c0000000a00000
  #endif
  msr S3_4_C10_C2_2, x0
  mov x0, #2
  msr S3_4_C2_C0_3, x0
  #endif
  dsb sy
  isb
  tlbi alle2
  dsb sy
  isb
  mrs x0, sctlr_el2
  orr x0, x0, #1
  msr sctlr_el2, x0
  isb
  #ifndef TEST_GCS
  bl tarwin_vhe_copy_probe
  cbnz w0, failed
  #endif
  // Switching away while running from the low identity map must refuse.
  msr pan, #1
  ldr x0, =private_a
  ldr x1, =host_root
  bl tarwin_w1_switch_user_root
  cbnz w0, failed
  mov x20, #0xffff800000000000
  adr x0, .Lupper
  add x0, x0, x20
  br x0
.Lupper:
  bti j
  add sp, sp, x20
  ldr x0, =tarwin_w1_vectors
  add x0, x0, x20
  msr vbar_el2, x0
  ldr x19, =context
  add x19, x19, x20
  msr tpidr_el2, x19
  isb
  #ifdef TEST_TIME_PAGE
  mov x0, x19
  bl tarwin_publish_shared_clock
  cbz w0, failed
  #endif
  #ifdef TEST_GCS
  #ifdef TEST_SLICE
  #include "slice.inc"
  #endif
  // Do not install a direct-permission TTBR0 under permission indirection.
  ldr x0, =private_a
  ldr x1, =host_root
  bl tarwin_w1_switch_user_root
  cbnz w0, failed
  mrs x9, ttbr0_el2
  ldr x10, =root
  cmp x9, x10
  b.ne failed
  mov x0, x19
  mov w1, #0
  bl tarwin_vhe_switch // direct user root under guarded host
  cbnz w0, failed
  mov x0, x19
  mov w1, #1
  bl tarwin_vhe_switch
  #ifdef TEST_WRONG_BANK
  cbnz w0, failed
  mrs x9, ttbr0_el2
  ldr x10, =root
  cmp x9, x10
  b.ne failed
  adr x1, wrong_ok
  mov x0, #4
  hlt #0xf000
  adr x1, exit_ok
  b exit_host
  #endif
  cbz w0, failed
  #ifdef TEST_TIME_PAGE
  ldr x21, =0x7ff000000000
  at s1e0r, x21
  isb
  mrs x9, par_el1
  tbnz x9, #0, failed
  ubfx x9, x9, #12, #36
  ldr x10, =0x40224 // sample + nine 16 KiB pages
  cmp x9, x10
  b.ne failed
  at s1e0w, x21
  isb
  mrs x9, par_el1
  tbz x9, #0, failed
  adr x1, time_ro
  mov x0, #4
  hlt #0xf000
  #endif
  #ifdef TEST_HIGH_GENID
  // The identity root is gone. Prove type, PA and both privilege levels
  // before using the live read-only device in the private host mapping.
  ldr x21, =0xffff800041000000
  at s1e2r, x21
  isb
  mrs x0, par_el1
  tbnz x0, #0, failed
  lsr x1, x0, #56
  cbnz x1, failed
  ubfx x0, x0, #12, #36
  ldr x1, =0x90d0
  cmp x0, x1
  b.ne failed
  at s1e2w, x21
  isb
  mrs x0, par_el1
  tbz x0, #0, failed
  at s1e0r, x21
  isb
  mrs x0, par_el1
  tbz x0, #0, failed
  ldr x0, =0x090d0000
  at s1e2r, x0
  isb
  mrs x0, par_el1
  tbz x0, #0, failed
  mov x0, x19
  bl tarwin_vhe_sample_generation
  cbz w0, failed
  adr x1, genid_ok
  mov x0, #4
  hlt #0xf000
  #endif
  mov x21, #0x80000000000
  add x21, x21, #4, lsl #12
  mov x22, #0xcb34
  gcssttr x22, [x21]
  gcsb dsync
  mov x0, x21
  mov x1, #0x5555
  bl tarwin_w1_store_user_word
  cbnz w0, failed
  mov x0, x21
  mov x1, x19
  bl tarwin_w1_load_user_word
  cbz w0, failed
  ldr x0, [x19]
  cmp x0, x22
  b.ne failed
  // Both guards deny unprivileged reads, while the RW neighbor of
  // the sealed private page is still writable under the same PIRE0.
  sub x0, x21, #4, lsl #12
  mov x1, x19
  bl tarwin_w1_load_user_word
  cbnz w0, failed
  add x0, x21, #4, lsl #12
  mov x1, x19
  bl tarwin_w1_load_user_word
  cbnz w0, failed
  ldr x21, =0x100008000
  mov x0, x21
  mov x1, x19
  bl tarwin_w1_load_user_word
  cbz w0, failed
  mov x0, x21
  mov x1, #0x739
  bl tarwin_w1_store_user_word
  cbnz w0, failed
  add x21, x21, #4, lsl #12
  mov x0, x21
  mov x1, #0x739
  bl tarwin_w1_store_user_word
  cbz w0, failed
  mov x0, x21
  mov x1, x19
  bl tarwin_w1_load_user_word
  cbz w0, failed
  ldr x0, [x19]
  cmp x0, #0x739
  b.ne failed
  // In this diagnostic no user runs. Round-trip the first-thread controls
  // only after the CPU selected the exact private root carrying its GCS.
  mrs x9, ttbr0_el2
  ldp x10, x11, [x19, #32]
  cmp x9, x10
  b.ne failed
  ldr x12, [x19, #48]
  mrs x13, gcspr_el0
  mrs x14, gcscre0_el1
  gcsb dsync
  msr gcspr_el0, x11
  msr gcscre0_el1, x12
  isb
  mrs x9, gcspr_el0
  mrs x10, gcscre0_el1
  cmp x9, x11
  ccmp x10, x12, #0, eq
  cset w15, eq
  msr gcscre0_el1, x14
  msr gcspr_el0, x13
  isb
  cbz w15, failed
  mrs x9, gcspr_el0
  mrs x10, gcscre0_el1
  cmp x9, x13
  ccmp x10, x14, #0, eq
  b.ne failed
  adr x1, gcs_ok
  mov x0, #4
  hlt #0xf000
  adr x1, exit_ok
  b exit_host
  #endif
  mov x0, x19
  mov w1, #0
  bl tarwin_vhe_switch
  cbz w0, failed
  // Refuse a different expected TTBR1; the next read must still use A.
  ldr x0, =private_b
  ldr x1, =private_a
  bl tarwin_w1_switch_user_root
  cbnz w0, failed
  mov x0, #0x100000000
  mov x1, x19
  bl tarwin_w1_load_user_word
  cbz w0, failed
  ldr x0, [x19]
  mov x1, #0x1234
  cmp x0, x1
  b.ne failed
  mov x0, x19
  mov w1, #1
  bl tarwin_vhe_switch
  cbz w0, failed
  mov x0, #0x100000000
  mov x1, x19
  bl tarwin_w1_load_user_word
  cbz w0, failed
  ldr x0, [x19]
  mov x1, #0xcafe
  cmp x0, x1
  b.ne failed
  // The obsolete low kernel mapping and the high stack guard are absent.
  ldr x0, =_start
  at s1e2r, x0
  isb
  mrs x0, par_el1
  tbz x0, #0, failed
  ldr x0, =stack_base
  add x0, x0, x20
  sub x0, x0, #8
  at s1e2r, x0
  isb
  mrs x0, par_el1
  tbz x0, #0, failed
  // A real STTR fault must still recover on the high private stack/vector.
  mov x0, #0x100000000
  mov x1, #0xaaaa
  bl tarwin_w1_store_user_word
  cbnz w0, failed
  at s1e0r, x19
  isb
  mrs x0, par_el1
  tbz x0, #0, failed
  adr x1, ok
  mov x0, #4
  hlt #0xf000
  // Register-only oracle with public diagnostic keys. No target is called;
  // the root contains no user code and no process key bank is provisioned.
  .arch_extension pauth
  mrs x25, sctlr_el2
  orr x9, x25, #(1 << 31)
  msr sctlr_el2, x9
  isb
  mov x21, #0x6754
  mov x22, #0xa901
  stp x21, x22, [sp, #-16]!
  msr APIAKeyLo_EL1, x21
  msr APIAKeyHi_EL1, x22
  isb
  mov x23, #0x100000000
  ldr x24, =0x9156000100004008
  pacia x23, x24
  mov x9, #0x100000000
  cmp x23, x9 // this fixed diagnostic tuple must exercise a nonzero PAC
  b.eq failed
  mov x21, #0xd3f0
  mov x22, #0x91e4
  msr APIAKeyLo_EL1, x21
  msr APIAKeyHi_EL1, x22
  isb
  mov x0, #0x100000000
  mov x1, x24
  mov x2, sp
  ldr x3, =private_a // not the expected host root
  bl tarwin_w1_sign_private_import
  cbnz x0, failed
  mov x0, #0x100000000
  mov x1, x24
  mov x2, sp
  ldr x3, =host_root
  bl tarwin_w1_sign_private_import
  cmp x0, x23
  b.ne failed
  orr x4, x4, x5
  orr x4, x4, x6
  orr x4, x4, x7
  cbnz x4, failed
  mrs x4, APIAKeyLo_EL1
  cmp x4, x21
  b.ne failed
  mrs x4, APIAKeyHi_EL1
  cmp x4, x22
  b.ne failed
  bic x9, x25, #(1 << 31)
  msr sctlr_el2, x9
  isb
  mov x0, #0x100000000
  mov x1, x24
  mov x2, sp
  ldr x3, =host_root
  bl tarwin_w1_sign_private_import
  cbnz x0, failed
  add sp, sp, #16
  msr sctlr_el2, x25
  isb
  adr x1, pac_ok
  mov x0, #4
  hlt #0xf000
  // Dispatch has already been tested separately. Use the vector's stop
  // continuation with a synthetic private frame; do not enter EL0.
  sub sp, sp, #816
  mov w0, #2
  b tarwin_w1_finish_private
.globl tarwin_w1_stopped_private
tarwin_w1_stopped_private:
  mov x3, sp
  cmp x3, x1
  b.ne failed
  ldr x4, =scheduler_top
  mov x5, #0xffff800000000000
  add x4, x4, x5
  cmp x1, x4
  b.ne failed
  ldr x4, =context
  add x4, x4, x5
  cmp x0, x4
  b.ne failed
  ldr x4, =host_root
  cmp x2, x4
  b.ne failed
  cbnz x29, failed
  mrs x4, daif
  and x4, x4, #0x3c0
  cmp x4, #0x3c0
  b.ne failed
  // Verify this is writable stack space, not just the expected SP value.
  stp x0, x1, [sp, #-16]!
  ldp x6, x7, [sp], #16
  cmp x6, x0
  b.ne failed
  cmp x7, x1
  b.ne failed
  adr x1, stopped
  mov x0, #4
  hlt #0xf000
  adr x1, exit_ok
  b exit_host
.globl tarwin_w1_dispatch_private
#ifdef TEST_HIGH_GENID
genid_absent:
  adr x1, genid_missing
  mov x0, #4
  hlt #0xf000
  adr x1, exit_ok
  b exit_host
genid_missing: .asciz "VHE-VMGEN-ABSENT-NO-MMIO-OR-EL0\\n"
.p2align 2
#endif
tarwin_w1_dispatch_private:
failed:
  adr x1, bad
  mov x0, #4
  hlt #0xf000
  adr x1, exit_bad
exit_host:
  mov x0, #0x20
  hlt #0xf000
  b .
hex_digit:
  cmp x2, #10
  add x0, x2, #48
  add x2, x2, #87
  csel x0, x0, x2, lo
  strb w0, [x1], #1
  ret
ok: .asciz "VHE-COPY-READ-WRITE-ABORT-DENY\\nVHE-HIGH-HOST-PRIVATE-ROOT-SWITCH\\n"
bad: .asciz "VHE-COPY-FAILED\\n"
gcs_ok: .asciz "VHE-GCS-STORE-ORDINARY-WRITE-DENIED\\nVHE-PRIVATE-PIE-RELRO-GUARD\\nVHE-FIRST-GCS-REGS-RESTORED\\n"
wrong_ok: .asciz "VHE-REFUSED-MISMATCHED-PIE-BANK\\n"
pac_ok: .asciz "VHE-IMPORT-IA-HOST-KEY-RESTORED\\n"
stopped: .asciz "VHE-STOP-ON-SEPARATE-SCHEDULER-STACK\\n"
genid_ok: .asciz "VHE-VMGEN-KERNEL-READONLY-NO-IDENTITY-OR-USER-ACCESS\\n"
time_ro: .asciz "VHE-TIME-PAGE-EL0-RO\\n"
.p2align 3
exit_ok: .quad 0x20026,0
exit_bad: .quad 0x20026,1

.data
gcs_report: .ascii "VHE-CPU-GCS-S1PIE-TCRX="
gcs_features: .asciz "000\\n"
.p2align 14
root: .quad l1+3
.p2align 14
l1: .quad l2+3
.p2align 14
l2: .space 32*8
    .quad ktext+3
    .space (128-33)*8
    .quad user+3
.p2align 14
ktext: .space 32*8
  .quad 0x0040000040080783,0x0040000040084783
""")
// Bootstrap code and data occupy disjoint 16 KiB pages. Keep the user
// sample at PA 0x40200000 outside this privileged identity mapping.
for i in 34..<128 {
  let pa: UInt64 = 0x4000_0000 + UInt64(i)*16384
  print(".quad 0x" + String(pa | 0x0060_0000_0000_0703, radix: 16))
}
print("""
.p2align 14
user: .quad 0x0060000040200fc3,0,0x0060000040204783,0x0060000040208f43
.p2align 14
host_root: .space 65536
private_a: .space 65536
private_b: .space 163840
context: .space 16384
  .space 16384
stack_base:
  .space 32768
stack_top:
  .space 16384
scheduler_base:
  .space 32768
scheduler_top:
.section .sample,"a"
sample:
.quad 0x1234,0x5678
.space 16384-24
.quad 0xfeed
.quad 0xcafe
.space 5*16384-8
#ifdef TEST_SLICE
.p2align 14
slice_start:
  .inst 0xd503245f // BTI c
  #ifdef TEST_PROCESS
  bl slice_start + 16384  // distinct user RX mapping of the actual LibTessera body
  mov x16, #88
  svc #0                 // outside the library, x0 holds the body return value
  b .
  #else
  #ifdef TEST_TIME_PAGE
  str x0, [sp, #-16]!
  mov w0, #1
  bl .Lclock_reader
  mov w4, w0
  ldr x0, [sp], #16
  #endif
  mov x10, #0x2567
  mov x11, #0x4819
  mov x12, x10
  pacia x12, x11
  mov x13, x10
  pacib x13, x11
  mov x14, x10
  pacda x14, x11
  mov x15, x10
  pacdb x15, x11
  pacga x17, x10, x11
  mrs x9, tpidrro_el0
  mrs x7, tpidr_el0
  str x0, [sp, #-16]!
  ldr x6, [sp], #16
  bl .Ltest_leaf
  svc #0
slice_after_first:
  mov x5, x0
  #ifdef TEST_TIME_PAGE
  // Preserve the dispatch and register oracles across this user call.
  stp x5, x6, [sp, #-16]!
  stp x7, x9, [sp, #-16]!
  stp x12, x13, [sp, #-16]!
  stp x14, x15, [sp, #-16]!
  stp x17, x30, [sp, #-16]!
  mov w0, #2
  bl .Lclock_reader
  mov w4, w0
  ldp x17, x30, [sp], #16
  ldp x14, x15, [sp], #16
  ldp x12, x13, [sp], #16
  ldp x7, x9, [sp], #16
  ldp x5, x6, [sp], #16
  mov x0, x5
  #endif
  svc #0
slice_after_second:
  b .
  .Ltest_leaf:
  ret
  #endif
  #ifdef TEST_TIME_PAGE
  .balign 4096
  .Lclock_reader:
  .incbin "reader.bin"
  #endif
  .p2align 14
  .space 32768
  #ifdef TEST_PROCESS
  lib_start:
  .incbin "process-body.bin"
  lib_end:
  .p2align 14
  #endif
  #ifdef TEST_TIME_PAGE
  .space 16384
  #endif
#endif
""")
