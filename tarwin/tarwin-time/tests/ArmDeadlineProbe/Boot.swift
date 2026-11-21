// IRQs are unmasked only inside timer_probe_wait, never in Swift; the
// exception handler uses and preserves two scratch registers.
let watchdog = CommandLine.arguments.dropFirst().first == "watchdog"
print("""
.section .text.boot,"ax"
.globl _start
_start:
  mov x19, x0
  msr daifset, #15
  mrs x0, CurrentEL
  cmp x0, #4
  b.ne failed
  msr spsel, #1
  adr x0, stack_top
  mov sp, x0
  adr x0, vectors
  msr vbar_el1, x0
  isb
  \(watchdog ? "mov x0, x19" : "adr x0, state")
  bl \(watchdog ? "watchdog_probe" : "timer_probe")
  \(watchdog ? "cmp w0, #2\n  b.eq refused" : "")
  cbnz w0, failed
  adr x1, ok
print_ok:
  mov x0, #4
  hlt #0xf000
  adr x1, ok_exit
  b exit
failed:
  adr x1, bad
  mov x0, #4
  hlt #0xf000
  adr x1, bad_exit
exit:
  mov x0, #0x20
  hlt #0xf000
  b .
.global timer_probe_enable
timer_probe_enable:
  dsb sy
  mrs x0, icc_sre_el1
  orr x0, x0, #1
  msr icc_sre_el1, x0
  isb
  mov x0, #0xff
  msr icc_pmr_el1, x0
  msr icc_bpr1_el1, xzr
  msr icc_ctlr_el1, xzr
  mov x0, #1
  msr icc_igrpen1_el1, x0
  isb
  ret
.global timer_probe_status
timer_probe_status:
  mrs x0, cntv_ctl_el0
  ret
.global timer_probe_wait
timer_probe_wait:
  // WFI with DAIF.I set cannot miss a timer which arrives before WFI.
  adr x0, state
  ldar x2, [x0]
  wfi
  msr daifclr, #2
  isb
1: ldar x1, [x0]
  cmp x1, x2
  b.eq 1b
  msr daifset, #2
  ret
.p2align 11
vectors:
""")
for i in 0..<16 {
  print(i == 5 ? "b irq" : "b failed")
  print(".balign 128")
}
print("""
irq:
  stp x9, x10, [sp, #-16]!
  mrs x9, icc_iar1_el1
  cmp x9, #27
  b.ne failed
  adr x10, state
  str x9, [x10, #8]
  mrs x9, cntvct_el0
  str x9, [x10, #16]
  // Clear the level source before dropping the GIC's active priority.
  msr cntv_ctl_el0, xzr
  isb
  mov x9, #27
  msr icc_eoir1_el1, x9
  isb
  ldr x9, [x10]
  add x9, x9, #1
  stlr x9, [x10]
  ldp x9, x10, [sp], #16
  eret
ok: .asciz "\(watchdog ? "ARM-WATCHDOG-RESET-AND-REENTRY\\n" : "ARM-DEADLINE-PPI27-SLICE-AND-TICKLESS-IDLE\\nARM-TWO-TIMERS-ONE-IRQ\\n")"
bad: .asciz "ARM-DEADLINE-FAILED\\n"
.p2align 3
ok_exit: .quad 0x20026,0
bad_exit: .quad 0x20026,1
.bss
.balign 16
state: .space 32
.space 16384
stack_top:
""")
if watchdog {
  print("""
  .text
  .global watchdog_probe_barrier
  watchdog_probe_barrier:
    dsb sy
    ret
  .global watchdog_probe_wait
  watchdog_probe_wait:
    adr x1, no_dispatch
    mov x0, #4
    hlt #0xf000
  1: wfi
    b 1b
  no_dispatch: .asciz "ARM-WATCHDOG-DISPATCH-STOPPED\\n"
  .balign 4
  refused:
    adr x1, no_watchdog
    b print_ok
  no_watchdog: .asciz "ARM-WATCHDOG-FIRMWARE-REFUSED\\n"
  """)
}
