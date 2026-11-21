let irq = CommandLine.arguments.dropFirst().first == "irq"
let kernel = CommandLine.arguments.dropFirst().first == "kernel"
// Hosted emitter for the standalone TCG diagnostic. Its dedicated EL2 core
// never runs W1 host code or an untrusted guest. Not a kernel variant body.
print(
  """
  .section .text.entry,"ax"
  .global _start
  _start:
    msr daifset, #15
    mrs x0, CurrentEL
    cmp x0, #8
    b.ne .Lfail
    ldr x0, =stack_top
    mov sp, x0
    adr x0, vectors
    msr vbar_el2, x0
    mov x0, #(1 << 34)
    orr x0, x0, #(1 << 31)
    orr x0, x0, #(1 << 27)
    \(irq || kernel ? "" : "orr x0,x0,#(1<<13)\n  orr x0,x0,#(1<<18)") // TWI/TID3 in the exit diagnostic
    msr hcr_el2, x0
    isb
    mrs x0, hcr_el2
    tbz x0, #34, .Lfail
    // Trap FP/SIMD use rather than sharing the host vector bank.
    mrs x0, cptr_el2
    bic x0, x0, #(3 << 20)
    msr cptr_el2, x0
    isb
    ldr x0, =arena
    ldr x1, =\(irq ? "irq_guest" : "guest_page")
    ldr x2, =data_page
    ldr x3, =exit_bank
    bl run_probe
    cbz w0, .Lfail
    adr x0, passed
    b .Lprint
  .Lfail:
    adr x0, failed
  .Lprint:
    ldr x1, =0x09000000
  1:
    ldrb w2, [x0], #1
    cbz w2, 2f
    str w2, [x1]
    b 1b
  2: wfe
     b 2b
  passed: .asciz "TARWIN \(irq ? "arm IRQ TIMER" : kernel ? "DEBUG CONSOLE" : "EL2 STAGE2") PASS\\n"
  failed: .asciz "TARWIN EL2 STAGE2 FAIL\\n"
  .balign 2048
  vectors:
  """)
for i in 0..<16 { print("b " + (i == 8 ? "lower_sync" : ".Lfail") + "\n.space 124") }
print(
  """
  .global probe_enter
  probe_enter:
    // x0: root, x1: VTCR, x2: private bank. Dedicated VMID 1 only.
    // The host stack, return address and bank pointer are never guest-mapped.
    stp x29, x30, [sp, #-16]!
    str x2, [sp, #-16]!
    orr x0, x0, #(1 << 48)
    msr vttbr_el2, x0
    msr vtcr_el2, x1
    isb
    dsb ishst
    mrs x9, hcr_el2
    bic x9, x9, #(1 << 27)
    orr x9, x9, #1
    msr hcr_el2, x9
    isb
    // Fixed guest configuration, PSTATE.DAIF masked, EL1h. No MMU
    // at stage 1. Only stage 2 can translate the guest's code/data IPAs.
    ldr x9, =0x30d00800
    msr sctlr_el12, x9
    ldr x9, [x2, #288]
    msr sp_el1, x9
    ldp x9, x10, [x2, #248]
    msr elr_el2, x9
    msr spsr_el2, x10
    // AAPCS host GPRs must survive an EL1 interval.
  """)
for i in stride(from: 18, through: 28, by: 2) { print("stp x\(i), x\(i+1), [sp, #-16]!") }
print("mov x30, x2")
for i in stride(from: 0, through: 28, by: 2) { print("ldp x\(i), x\(i+1), [x30, #\(8*i)]") }
print(
  """
    ldr x30, [x30, #240]
    isb
    eret
  lower_sync:
    // Stack is the private SP_EL2, not SP_EL1. No access to guest pointers.
    stp x0, x1, [sp, #-16]!
    ldr x0, [sp, #112]
  """)
for i in stride(from: 2, through: 28, by: 2) { print("stp x\(i), x\(i+1), [x0, #\(8*i)]") }
print(
  """
    str x30, [x0, #240]
    ldp x9, x10, [sp], #16
    stp x9, x10, [x0]
    mrs x9, elr_el2
    mrs x10, spsr_el2
    stp x9, x10, [x0, #248]
    mrs x9, esr_el2
    mrs x10, far_el2
    stp x9, x10, [x0, #264]
    mrs x9, hpfar_el2
    str x9, [x0, #280]
    mrs x9, sp_el1
    str x9, [x0, #288]
    mrs x9, hcr_el2
    bic x9, x9, #1
    orr x9, x9, #(1 << 27)
    msr hcr_el2, x9
    isb
  """)
for i in stride(from: 28, through: 18, by: -2) { print("ldp x\(i), x\(i+1), [sp], #16") }
print(
  """
    add sp, sp, #16
    ldp x29, x30, [sp], #16
    ret
  .global probe_invalidate
  probe_invalidate:
    // The currently selected VTTBR still names this sole VMID. TGE must
    // be clear for the EL1&0 guest regime; never execute a host load there.
    mrs x9, hcr_el2
    bic x10, x9, #(1 << 27)
    msr hcr_el2, x10
    isb
    dsb ishst
    tlbi vmalls12e1is
    dsb ish
    isb
    msr hcr_el2, x9
    isb
    ret

  .balign 16384
  guest_page:
    mrs x0, CurrentEL
    mov x1, #0x2000000
    mov x2, #0x5347
    str x2, [x1]
    hvc #0x42
    add x13, x6, x30
    hvc #0x46
    // Host revoked write; an L3 permission abort must precede the store.
    mov x2, #0xdead
    str x2, [x1]
    // Host detached the data page; an L3 translation abort must follow.
    ldr x3, [x1]
    // A separate unmapped IPA is registered to a host MMIO device.
    mov x4, #0x4000000
    strh w2, [x4, #2]
    ldrsb x5, [x4, #1]
    hvc #0x43
    wfi
    mrs x7, ID_AA64PFR0_EL1
    hvc #0x44
    mov x8, #0x7101
    str x8, [x1]
    hvc #0x45
    add x8, x8, #1
    str x8, [x1]
    hvc #0x45
    // Host restored a data page; executing from it must fault.
    br x1
    .balign 16384
  .section .bss,"aw",%nobits
  .balign 16384
  arena: .skip 49152
  data_page: .skip 16384
  exit_bank: .skip 296
  .balign 16
  .skip 32768
  stack_top:
  """)
