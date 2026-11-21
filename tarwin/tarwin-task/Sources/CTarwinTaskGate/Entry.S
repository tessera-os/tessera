#if defined(__aarch64__)
  .text
  .p2align 2

  .macro push_frame
  sub sp, sp, #704
  stp x0, x1, [sp, #0]
  stp x2, x3, [sp, #16]
  stp x4, x5, [sp, #32]
  stp x6, x7, [sp, #48]
  str x16, [sp, #64]
  stp x8, x9, [sp, #72]
  stp x10, x11, [sp, #88]
  stp x12, x13, [sp, #104]
  stp x14, x15, [sp, #120]
  stp x18, x30, [sp, #144]
  mrs x9, nzcv
  mrs x10, fpcr
  mrs x11, fpsr
  stp x9, x10, [sp, #160]
  str x11, [sp, #176]
  stp q0, q1, [sp, #192]
  stp q2, q3, [sp, #224]
  stp q4, q5, [sp, #256]
  stp q6, q7, [sp, #288]
  stp q8, q9, [sp, #320]
  stp q10, q11, [sp, #352]
  stp q12, q13, [sp, #384]
  stp q14, q15, [sp, #416]
  stp q16, q17, [sp, #448]
  stp q18, q19, [sp, #480]
  stp q20, q21, [sp, #512]
  stp q22, q23, [sp, #544]
  stp q24, q25, [sp, #576]
  stp q26, q27, [sp, #608]
  stp q28, q29, [sp, #640]
  stp q30, q31, [sp, #672]
  .endm

  .macro pop_frame
  ldp q0, q1, [sp, #192]
  ldp q2, q3, [sp, #224]
  ldp q4, q5, [sp, #256]
  ldp q6, q7, [sp, #288]
  ldp q8, q9, [sp, #320]
  ldp q10, q11, [sp, #352]
  ldp q12, q13, [sp, #384]
  ldp q14, q15, [sp, #416]
  ldp q16, q17, [sp, #448]
  ldp q18, q19, [sp, #480]
  ldp q20, q21, [sp, #512]
  ldp q22, q23, [sp, #544]
  ldp q24, q25, [sp, #576]
  ldp q26, q27, [sp, #608]
  ldp q28, q29, [sp, #640]
  ldp q30, q31, [sp, #672]
  ldp x9, x10, [sp, #160]
  ldr x11, [sp, #176]
  msr nzcv, x9
  msr fpcr, x10
  msr fpsr, x11
  ldp x18, x30, [sp, #144]
  ldp x14, x15, [sp, #120]
  ldp x12, x13, [sp, #104]
  ldp x10, x11, [sp, #88]
  ldp x8, x9, [sp, #72]
  ldr x16, [sp, #64]
  ldp x6, x7, [sp, #48]
  ldp x4, x5, [sp, #32]
  ldp x2, x3, [sp, #16]
  ldp x0, x1, [sp]
  add sp, sp, #704
  .endm

  .globl _tarwin_task_gate_entry
_tarwin_task_gate_entry:
  push_frame
  mov x0, sp
  bl _tarwin_task_gate_bridge
  cbnz w0, 1f
  pop_frame
  ret
1:
  brk #0x7f57

  .globl _tarwin_task_tls_entry
_tarwin_task_tls_entry:
  push_frame
  bl _tarwin_task_tls_bridge
  str x0, [sp]
  pop_frame
  ret
#endif
