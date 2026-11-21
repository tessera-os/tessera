let kernel = CommandLine.arguments.dropFirst().first == "kernel"
// A dedicated QEMU hart enters VS-mode from OpenSBI's S-mode payload.
// No production trap vector, interrupt path or untrusted guest is installed.
print(
  """
  .option norvc
  .option norelax
  .section .text.entry,"ax"
  .global _start
  _start:
    csrci sstatus, 2
    csrw sie, zero
    la sp, stack_top
    la gp, __global_pointer$
    la t0, failed
    csrw stvec, t0
    csrw hedeleg, zero
    csrw hideleg, zero
    csrw vsatp, zero
    csrw vsie, zero
    csrw vsstatus, zero
    la a0, arena
    la a1, guest_page
    la a2, data_page
    la a3, bank
    call run_rv_probe
    beqz a0, failed
    la a0, pass_string
    j print_result
  .balign 4
  failed:
    la a0, fail_string
  print_result:
    li t0, 0x10000000
  1: lbu t1, 0(a0)
     beqz t1, 2f
     sb t1, 0(t0)
     addi a0, a0, 1
     j 1b
  2: wfi
     j 2b
  pass_string: .asciz "TARWIN \(kernel ? "DEBUG CONSOLE" : "RV64 GSTAGE") PASS\\n"
  fail_string: .asciz "TARWIN RV64 GSTAGE FAIL\\n"
  .balign 4
  .global rv_enter
  rv_enter:
    // a0: hgatp (Sv48x4), a1: private bank. Save psABI-preserved
    // state plus gp/tp in HS-only RAM. sscratch holds the HS stack.
    addi sp, sp, -160
    sd ra, 0(sp)
    sd gp, 8(sp)
    sd tp, 16(sp)
    sd a1, 24(sp)
  """)
let saved = [8, 9] + Array(18...27)
for (i, r) in saved.enumerated() { print("sd x\(r), \(32 + 8*i)(sp)") }
print(
  """
    la t0, trap
    csrw stvec, t0
    csrw hgatp, a0
    csrr t1, hgatp
    bne t1, a0, failed
    hfence.gvma zero, zero
    ld t0, 256(a1)
    csrw sepc, t0
    li t0, (1 << 7) | (1 << 8)
    csrs hstatus, t0
    li t0, (1 << 8)
    csrs sstatus, t0
    csrw sscratch, sp
    mv t6, a1
  """)
for r in 1...31 { print("ld x\(r), \(8*r)(t6)") }
print(
  """
    sret
  .balign 4
  trap:
    csrrw sp, sscratch, sp
    sd t6, 128(sp)
    ld t6, 24(sp)
  """)
for r in 1...30 where r != 2 { print("sd x\(r), \(8*r)(t6)") }
print(
  """
    ld t0, 128(sp)
    sd t0, 248(t6)
    csrr t0, sscratch
    sd t0, 16(t6)
    csrr t0, sepc
    sd t0, 256(t6)
    csrr t0, scause
    sd t0, 264(t6)
    csrr t0, stval
    sd t0, 272(t6)
    csrr t0, htval
    sd t0, 280(t6)
    csrr t0, hstatus
    sd t0, 288(t6)
    andi t0, t0, 128
    beqz t0, failed
    la t0, failed
    csrw stvec, t0
    csrw sscratch, zero
  """)
for (i, r) in saved.enumerated() { print("ld x\(r), \(32 + 8*i)(sp)") }
print(
  """
    ld ra, 0(sp)
    ld gp, 8(sp)
    ld tp, 16(sp)
    addi sp, sp, 160
    ret
  .global rv_flush
  rv_flush:
    fence rw, rw
    hfence.gvma zero, zero
    ret

  .balign 4096
  guest_page:
    li a1, 0x200000
    li a2, 0x5347
    sd a2, 0(a1)
    ecall
    li a2, 0xdead
    sd a2, 0(a1)
    ld a3, 0(a1)
    jr a1
  .balign 4096
  .section .bss,"aw",%nobits
  .balign 16384
  arena: .skip \(kernel ? 65536 : 32768)
  data_page: .skip 4096
  bank: .skip 296
  .balign 16
  .skip 32768
  stack_top:
  """)
