// One boot-CPU EL0 interval. No Swift call, scheduler lock acquisition,
// or indirect branch runs with user keys in privileged state. A sync trap
// returns the captured bank to the caller under its original root and keys.
func emitArmGuardedSlice() {
  typealias F = ArmTrapLayout
  let keys = ["APIA", "APIB", "APDA", "APDB", "APGA"]
  let single = ["ttbr0_el2", "vbar_el2", "sp_el0", "tpidr_el0", "tpidrro_el0",
    "elr_el2", "spsr_el2", "cptr_el2", "gcspr_el0", "gcscre0_el1", "fpcr", "fpsr"]
  let host = 816 // private host spill above the 816-byte hardware capture
  print("""
  .arch_extension gcs
  .p2align 11
  .Lslice_vectors:
  """)
  for i in 0..<16 {
    print("b " + (i == 8 ? ".Llower_sync" : ".Lhalt") + "\n.space 124")
  }
  print("""
  .global tarwin_w1_guarded_slice
  .hidden tarwin_w1_guarded_slice
  tarwin_w1_guarded_slice:
  bti c
  // x0/x1: finished user/host roots; x2: ten private key words;
  // x3: exact private architectural frame; x4: private GCS cursor.
  mrs x9, CurrentEL
  cmp x9, #8
  b.ne .Lbad_mode
  mrs x9, hcr_el2
  tbz x9, #34, .Lbad_mode
  tbz x9, #27, .Lbad_mode
  mrs x9, cptr_el2
  tst x9, #(3 << 24) // No active host SME or SVE context.
  b.ne .Lbad_mode
  tst x9, #(3 << 16)
  b.ne .Lbad_mode
  mrs x9, id_aa64pfr1_el1
  ubfx x9, x9, #44, #4
  cmp x9, #1
  b.ne .Lbad_mode
  mrs x9, gcscr_el2
  cbnz x9, .Lbad_mode
  mrs x9, id_aa64isar1_el1
  mrs x10, S3_0_C0_C6_2 // ID_AA64ISAR2_EL1
  ubfx x11, x9, #4, #8 // APA/API
  ubfx x12, x10, #12, #4 // APA3
  orr x11, x11, x12
  cbz x11, .Lbad_mode
  ubfx x11, x9, #24, #8 // GPA/GPI
  ubfx x12, x10, #8, #4 // GPA3
  orr x11, x11, x12
  cbz x11, .Lbad_mode
  mrs x9, sctlr_el2
  ldr x10, =0xc8002000 // all four PAC enables
  and x11, x9, x10
  cmp x11, x10
  b.ne .Lbad_mode
  tbnz x9, #60, .Lbad_mode // no EL0 TPIDR2
  tbnz x9, #24, .Lbad_mode // little-endian EL0 and host
  tbnz x9, #25, .Lbad_mode
  adr x9, tarwin_w1_vectors
  mrs x10, vbar_el2
  cmp x9, x10
  b.ne .Lbad_mode
  mov x9, #0xffff800000000000
  cmp x2, x9
  ccmp x3, x9, #0, hs
  ccmp x4, x9, #0, hs
  b.lo .Lbad_mode
  orr x10, x2, x4
  tst x10, #7
  b.ne .Lbad_mode
  tst x3, #15
  b.ne .Lbad_mode
  // x5...x6 come from ArmStopStacks for the currently owned host root.
  mov x10, sp
  cmp x10, x6
  b.hi .Lbad_mode
  sub x10, x10, #\(host+F.size)
  cmp x10, x5
  b.lo .Lbad_mode
  ldr x9, [x3, #\(F.spsr)]
  tst x9, #31
  b.ne .Lbad_mode
  sub sp, sp, #\(host)
  // Save LR and all nonvolatile GPRs before the checked root exchange.
  """)
  for i in stride(from: 19, through: 29, by: 2) {
    print("stp x\(i), x\(i+1), [sp, #\(80+(i-19)*8)]")
  }
  print("""
  str x18, [sp, #800]
  stp x3, x4, [sp, #272]
  mov x19, x2
  mrs x9, ttbr0_el2
  str x9, [sp, #176]
  bl tarwin_w1_switch_guarded_root
  cbz w0, .Lslice_refused
  """)
  for (i, r) in single.enumerated() where i != 0 {
    print("mrs x9, \(r)\nstr x9, [sp, #\(176+i*8)]")
    if r == "cptr_el2" {
      print("""
      bic x9, x9, #(3 << 16)
      bic x9, x9, #(3 << 24)
      orr x9, x9, #(3 << 20)
      msr cptr_el2, x9
      isb
      """)
    }
  }
  for i in stride(from: 0, to: 32, by: 2) {
    print("stp q\(i), q\(i+1), [sp, #\(288+i*16)]")
  }
  for (i, k) in keys.enumerated() {
    print("""
    mrs x9, \(k)KeyLo_EL1
    mrs x10, \(k)KeyHi_EL1
    stp x9, x10, [sp, #\(16*i)]
    ldp x9, x10, [x19, #\(16*i)]
    msr \(k)KeyLo_EL1, x9
    msr \(k)KeyHi_EL1, x10
    """)
  }
  print("""
  msr tpidrro_el0, xzr
  ldp x11, x12, [sp, #272]
  ldr x12, [x12]
  gcsb dsync
  msr gcspr_el0, x12
  mov x12, #\(ArmInitialControlStack.control)
  msr gcscre0_el1, x12
  adr x9, .Lslice_vectors
  msr vbar_el2, x9
  isb
  sub sp, sp, #\(F.size)
  mov x10, sp
  mov x12, #\(F.size/16)
  1: ldp x13, x14, [x11], #16
  stp x13, x14, [x10], #16
  subs x12, x12, #1
  b.ne 1b
  // Only NZCV is caller-visible in this baseline. Never restore EL, DAIF,
  // debug, PAN, SSBS, streaming mode or other controls from frame storage.
  ldr x9, [sp, #\(F.spsr)]
  and x9, x9, #0xf0000000
  str x9, [sp, #\(F.spsr)]
  clrex
  b .Lresume
  .Lslice_trap:
  msr pan, #1
  mov x11, sp
  add sp, sp, #\(F.size)
  ldp x10, x12, [sp, #272]
  gcsb dsync
  mrs x9, gcspr_el0
  str x9, [x12]
  mov x12, #\(F.size/16)
  1: ldp x13, x14, [x11], #16
  stp x13, x14, [x10], #16
  subs x12, x12, #1
  b.ne 1b
  """)
  for (i, k) in keys.enumerated() {
    print("""
    ldp x9, x10, [sp, #\(16*i)]
    msr \(k)KeyLo_EL1, x9
    msr \(k)KeyHi_EL1, x10
    stp xzr, xzr, [sp, #\(16*i)]
    """)
  }
  for i in stride(from: 0, to: 32, by: 2) {
    print("ldp q\(i), q\(i+1), [sp, #\(288+i*16)]")
  }
  for (i, r) in single.enumerated().reversed() where i != 0 {
    print("ldr x9, [sp, #\(176+i*8)]\nmsr \(r), x9")
  }
  print("""
  ldr x9, [sp, #176]
  dsb ishst
  msr ttbr0_el2, x9
  isb
  tlbi alle2is
  dsb ish
  isb
  mov w0, #1
  .Lslice_refused:
  ldr x18, [sp, #800]
  """)
  for i in stride(from: 19, through: 29, by: 2) {
    print("ldp x\(i), x\(i+1), [sp, #\(80+(i-19)*8)]")
  }
  print("add sp, sp, #\(host)\nret\n.ltorg")
  print("""
  .global tarwin_w1_prior_root
  .hidden tarwin_w1_prior_root
  tarwin_w1_prior_root:
  bti c
  mrs x0, ttbr0_el2
  ret
  .global tarwin_w1_retire_slice_root
  .hidden tarwin_w1_retire_slice_root
  tarwin_w1_retire_slice_root:
  bti c
  mrs x9, ttbr0_el2
  cmp x9, x1
  b.ne .Lhalt
  mrs x9, ttbr1_el2
  cmp x9, x2
  b.ne .Lhalt
  mrs x9, daif
  and x9, x9, #0x3c0
  cmp x9, #0x3c0
  b.ne .Lhalt
  dsb ishst
  msr ttbr0_el2, x0
  isb
  tlbi alle2is
  dsb ish
  isb
  ret
  """)
}
