// Direct QEMU image, not a signed boot set. Require EL2 on both PEs and
// run with the MMU and caches off on separate static exception stacks.
print("""
.section .text.boot,"ax"
.globl _start
_start:
  adr x8, boot_top
  bl setup
  mov sp, x8
  mrs x1, mpidr_el1
  bl arm_smp_probe
  cbz w0, smp_probe_fail
  adr x1, ok
  cmp w0, #1
  b.eq 1f
  cmp w0, #2
  b.ne smp_probe_fail
  adr x1, refused
1:
  mov x0, #4
  hlt #0xf000
  adr x1, ok_exit
  b finish
.global smp_probe_fail
smp_probe_fail:
  adr x1, bad
  mov x0, #4
  hlt #0xf000
  adr x1, bad_exit
finish:
  mov x0, #0x20
  hlt #0xf000
  b .
setup:
  msr daifset, #15
  mrs x9, CurrentEL
  cmp x9, #8
  b.ne smp_probe_fail
  mrs x9, sctlr_el2
  tst x9, #1
  b.ne smp_probe_fail
  tbnz x9, #2, smp_probe_fail
  tbnz x9, #12, smp_probe_fail
  msr spsel, #1
  adr x9, vectors
  msr vbar_el2, x9
  msr cntvoff_el2, xzr
  isb
  ret
.balign 4
secondary:
  adr x8, secondary_top
  bl setup
  mov sp, x8
  mov x1, x0
  mrs x0, mpidr_el1
  movz x9, #0xffff
  movk x9, #0xff, lsl #16
  movk x9, #0xff, lsl #32
  and x0, x0, x9
  bl smp_probe_secondary
  movz w0, #2
  movk w0, #0x8400, lsl #16
  smc #0
  b smp_probe_fail
.global smp_probe_ticks
smp_probe_ticks:
  b tarwin_clock_ticks
.global smp_probe_secondary_entry
smp_probe_secondary_entry:
  adr x0, secondary
  ret
.global smp_probe_mailbox
smp_probe_mailbox:
  adr x0, smp_mail
  ret
.p2align 11
vectors:
""")
for _ in 0..<16 { print("b smp_probe_fail\n.balign 128") }
print("""
ok: .asciz "ARM-EL2-PSCI-TWO-CPU-PL031-CLOCK-PAGE-AND-OFF\\n"
refused: .asciz "ARM-UNSUPPORTED-FIRMWARE-CPU-START-REFUSED\\n"
bad: .asciz "ARM-SMP-CLOCK-FAILED\\n"
.balign 8
ok_exit: .quad 0x20026,0
bad_exit: .quad 0x20026,1
.bss
.balign 16384
smp_mail: .space 32768
.space 32768
boot_top:
.space 32768
secondary_top:
""")
