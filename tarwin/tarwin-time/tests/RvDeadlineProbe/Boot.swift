// Direct OpenSBI payload in S-mode. Only the wait veneer unmasks IRQs.
let aia = CommandLine.arguments.dropFirst().first == "aia"
let aiaMarkers = aia ? "RV64-APLIC-RTC-TO-SUPERVISOR-IMSIC-65\\nRV64-IRQ-PORT-MASKED-PENDING-REARM\\n" : ""
let claim = aia ? """
  csrrw t1, 0x15c, zero
  srli t1, t1, 16
  li t0, 65
  bne t0, t1, failed
  la t0, state
  sd t1, 16(t0)
""" : """
  li t0, 0x0c201004
  lw t1, (t0)
  li t0, 11
  bne t0, t1, failed
  la t0, state
  sd t1, 16(t0)
  li t0, 0x101010
  sw zero, (t0)
  sw t1, 12(t0)
  fence iorw, iorw
  li t0, 0x0c201004
  sw t1, (t0)
  fence iorw, iorw
"""
print("""
.section .text.boot,"ax"
.globl _start
.option norelax
_start:
  csrci sstatus, 2
  la sp, stack_top
  la t0, handler
  csrw stvec, t0
  la a2, state
  call rv_timer_probe
  beqz a0, delivered
  li t0, 3
  bne a0, t0, 1f
  la a1, smp_ok
  j good
1:
  li t0, 4
  bne a0, t0, 1f
  la a1, bad_rate
  j good
1:
  li t0, 6
  bne a0, t0, 1f
  la a1, bad_route
  j good
1:
  li t0, 5
  bne a0, t0, 1f
  la a1, no_aia
  j good
1:
  li t0, 1
  bne t0, a0, failed
  la a1, unsupported
  j good
delivered:
  la a1, ok
good:
  li a0, 4
  call host
  la a1, ok_exit
  j exit
.global smp_probe_fail
smp_probe_fail:
failed:
  la a1, bad
  li a0, 4
  call host
  la a1, bad_exit
exit:
  li a0, 0x20
  call host
  j .
.balign 16
.option push
.option norvc
host:
  slli zero, zero, 0x1f
  ebreak
  srai zero, zero, 7
  ret
.option pop
.global smp_probe_ticks
smp_probe_ticks:
  j tarwin_rv_ticks
.global smp_probe_mailbox
smp_probe_mailbox:
  la a0, smp_mail
  ret
.global smp_probe_secondary_entry
smp_probe_secondary_entry:
  la a0, secondary
  ret
.balign 4
secondary:
  csrci sstatus, 2
  csrw sie, zero
  la sp, secondary_top
  la t0, smp_probe_fail
  csrw stvec, t0
  fence rw, rw
  call smp_probe_secondary
  call tarwin_sbi_hsm_stop
  j failed
.global timer_probe_io_fence
timer_probe_io_fence:
  fence iorw, iorw
  ret
.global timer_probe_external_enable
timer_probe_external_enable:
  fence iorw, iorw
  li t0, 512
  csrs sie, t0
  ret
.global timer_probe_idle
timer_probe_idle:
  csrr a0, 0x14d
  addi a0, a0, 1
  csrr t0, sie
  andi t0, t0, 32
  or a0, a0, t0
  seqz a0, a0
  ret
.global timer_probe_wait
timer_probe_wait:
  la t0, state
  ld t2, (t0)
  wfi
  csrsi sstatus, 2
1: ld t1, (t0)
  beq t1, t2, 1b
  csrci sstatus, 2
  ret
.balign 4
handler:
  addi sp, sp, -16
  sd t0, (sp)
  sd t1, 8(sp)
  csrr t1, scause
  li t0, 0x8000000000000005
  bne t0, t1, external
  // Mask STIE as well as advancing stimecmp: STIP may clear late.
  li t0, 32
  csrc sie, t0
  li t0, -1
  csrw 0x14d, t0
  la t0, state
  rdtime t1
  sd t1, 8(t0)
  j handled
external:
  li t0, 0x8000000000000009
  bne t0, t1, failed
\(claim)
  li t0, 512
  csrc sie, t0
  la t0, state
handled:
  ld t1, (t0)
  addi t1, t1, 1
  sd t1, (t0)
  ld t0, (sp)
  ld t1, 8(sp)
  addi sp, sp, 16
  sret
ok: .asciz "RV64-SSTC-STIP-SLICE-AND-TICKLESS-IDLE\\nRV64-TWO-TIMERS-ONE-IRQ\\nRV64-RTC-WFI-WAKE-AND-DEFERRED-TIMER\\n\(aiaMarkers)"
no_aia: .asciz "RV64-NO-SSAIA-REFUSED\\n"
bad_route: .asciz "RV64-INVALID-SUPERVISOR-IRQ-ROUTE-REFUSED\\n"
unsupported: .asciz "RV64-NO-SSTC-REFUSED\\n"
bad_rate: .asciz "RV64-WRONG-TIMEBASE-REFUSED\\n"
smp_ok: .asciz "RV64-TWO-HART-CLOCK-RTC-CALIBRATION-PAGE-AND-STOP\\n"
bad: .asciz "RV64-DEADLINE-FAILED\\n"
.balign 8
ok_exit: .quad 0x20026,0
bad_exit: .quad 0x20026,1
.bss
.balign 16
state: .space 24
.balign 16
.space 32768
stack_top:
.space 16384
secondary_top:
.balign 4096
smp_mail: .space 8192
""")
