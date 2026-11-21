// Dedicated diagnostic only. The RX page contains two SVCs, not an image
// or an enrolled process. All keys in this oracle are public test values.
let keys = ["APIA", "APIB", "APDA", "APDB", "APGA"]
print("""
  .arch_extension pauth
  add x23, x19, #512  // private key bank
  add x24, x19, #1024 // aligned private frame
  add x25, x19, #256  // GCS cursor
  mrs x21, ttbr0_el2
  mrs x22, sctlr_el2
  ldr x9, =0xc8002000
  orr x9, x9, x22
  bic x9, x9, #(1 << 60)
  msr sctlr_el2, x9
  isb
  """)
for (i,k) in keys.enumerated() {
  print("""
  mov x9, #\(73+i*2)
  mov x10, #\(74+i*2)
  stp x9, x10, [x23, #\(i*16)]
  msr \(k)KeyLo_EL1, x9
  msr \(k)KeyHi_EL1, x10
  """)
}
print("""
  isb
  mov x9, #0x2567
  mov x10, #0x4819
  """)
for (i,op) in ["pacia","pacib","pacda","pacdb","pacga"].enumerated() {
  print("mov x11, x9")
  print(op == "pacga" ? "pacga x11, x9, x10" : "\(op) x11, x10")
  print("str x11, [x19, #\(384+8*i)]")
}
for (i,k) in keys.enumerated() {
  print("""
  mov x9, #\(903+i*2)
  mov x10, #\(904+i*2)
  msr \(k)KeyLo_EL1, x9
  msr \(k)KeyHi_EL1, x10
  """)
}
print("""
  isb
  ldr x9, [x19, #40]
  str x9, [x25]
  mov x9, #57
  str x9, [x24]
  ldr x9, =0x100010000
  str x9, [x24, #256]
  ldr x9, =0x80000024000
  str x9, [x24, #248]
  ldr x9, =0x80000028000
  str x9, [x24, #280]
  mov x9, #0x7ec
  msr tpidrro_el0, x9
  // Four refusals: disabled IA, hostile mode in a kernel frame, wrong
  // TTBR1, insufficient private stack. None may enter or switch roots.
  mov x27, #0
  .Lrefusals:
  ldr x0, =private_b
  ldr x1, =host_root
  mov x2, x23
  mov x3, x24
  mov x4, x25
  ldr x5, =stack_base
  add x5, x5, x20
  add x6, x5, #8, lsl #12
  cbnz x27, 1f
  mrs x28, sctlr_el2
  bic x9, x28, #(1 << 31)
  msr sctlr_el2, x9
  isb
  b 4f
  1: cmp x27, #1
  b.ne 2f
  mov x9, #9
  str x9, [x24, #264]
  b 4f
  2: cmp x27, #2
  b.ne 3f
  ldr x1, =private_a
  b 4f
  3: mov x5, sp
  4: bl tarwin_w1_guarded_slice
  cbnz w0, failed
  mrs x9, ttbr0_el2
  cmp x9, x21
  b.ne failed
  msr sctlr_el2, x28
  isb
  str xzr, [x24, #264]
  add x27, x27, #1
  cmp x27, #4
  b.lo .Lrefusals
  mov x26, #0
  .Ltest_slice:
  ldr x0, =private_b
  ldr x1, =host_root
  mov x2, x23
  mov x3, x24
  mov x4, x25
  ldr x5, =stack_base
  add x5, x5, x20
  add x6, x5, #8, lsl #12
  bl tarwin_w1_guarded_slice
  cbz w0, failed
  mrs x9, ttbr0_el2
  cmp x9, x21
  b.ne failed
  mrs x9, tpidrro_el0
  cmp x9, #0x7ec
  b.ne failed
  ldr x9, [x24, #264]
  tst x9, #31
  b.ne failed
  ldr x9, [x24, #272]
  ldr x10, =0x56000000 // 64-bit SVC #0 from lower EL
  cmp x9, x10
  b.ne failed
  ldr x9, [x24, #72] // user could not read host TPIDRRO_EL0
  cbnz x9, failed
  ldr x9, [x24, #48] // first x0 survived a push/pop on the user stack
  cmp x9, #57
  b.ne failed
  ldr x9, [x24, #56]
  ldr x10, =0x80000028000
  cmp x9, x10
  b.ne failed
  ldr x9, [x19, #40]
  ldr x10, [x25]
  cmp x9, x10
  b.ne failed
  """)
for (i,k) in keys.enumerated() {
  let reg = [12,13,14,15,17][i]
  print("""
  mrs x9, \(k)KeyLo_EL1
  mrs x10, \(k)KeyHi_EL1
  cmp x9, #\(903+i*2)
  b.ne failed
  cmp x10, #\(904+i*2)
  b.ne failed
  ldr x9, [x24, #\(reg*8)]
  ldr x10, [x19, #\(384+i*8)]
  cmp x9, x10
  b.ne failed
  """)
}
print("""
  cbnz x26, .Ltest_resumed
  ldr x9, [x24]
  cmp x9, #57
  b.ne failed
  ldr x9, [x24, #256]
  ldr x10, =0x100010000 + (slice_after_first-slice_start)
  cmp x9, x10
  b.ne failed
  mov x26, #1
  mov x0, x24
  ldr x1, =0x100010000 + (slice_after_first-slice_start)
  bl tarwin_test_dispatch_slice
  cmp w0, #1
  b.ne failed
  b .Ltest_slice
  .Ltest_resumed:
  ldr x9, [x24, #40]
  ldr x10, =0x10000000a // unavailable syscall
  cmp x9, x10
  b.ne failed
  ldr x9, [x24, #256]
  ldr x10, =0x100010000 + (slice_after_second-slice_start)
  cmp x9, x10
  b.ne failed
  mov x0, x24
  ldr x1, =0x100010000 + (slice_after_first-slice_start)
  bl tarwin_test_dispatch_slice // SVC outside the provider interval
  cbnz w0, failed
  adr x1, .Lslice_ok
  mov x0, #4
  hlt #0xf000
  adr x1, exit_ok
  b exit_host
  .Lslice_ok: .asciz "VHE-EL0-SVC-HOST-KEYS-AND-ROOT-RESTORED\\n"
  .p2align 2
  """)
