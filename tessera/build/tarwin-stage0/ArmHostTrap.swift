// Hosted Swift stage-0 bridge for the boot CPU's VHE EL2/0 exception
// regime. The caller provisions the guarded SP_EL2, private per-CPU context,
// host FP access, process keys, and immutable high-half code before use.
// No initial ERET. No scheduling, SVE/SME, interrupts, or EL1 guest exits.
@main struct HostTrapVariant {
  static func main() {
    typealias F = ArmTrapLayout
    print("""
    .text
    .p2align 11
    .global tarwin_w1_vectors
    tarwin_w1_vectors:
    """)
    for i in 0..<16 {
      let handler = i == 8 ? "lower_sync" : (i == 4 ? "copy_abort" : "halt")
      print("b .L\(handler)\n.space 124")
    }
    print("""
    .Lhalt:
    msr daifset, #15
    1: wfe
    b 1b
    .Llower_sync:
    msr daifset, #15
    sub sp, sp, #\(F.size)
    """)
    for i in stride(from: 0, to: 30, by: 2) {
      print("stp x\(i), x\(i+1), [sp, #\(i*8)]")
    }
    print("str x30, [sp, #240]\nclrex")
    let banks = [("sp_el0", F.sp), ("elr_el2", F.elr), ("spsr_el2", F.spsr),
      ("esr_el2", F.esr), ("tpidr_el0", F.tpidr), ("fpcr", F.fpcr), ("fpsr", F.fpsr)]
    for (reg, off) in banks { print("mrs x9, \(reg)\nstr x9, [sp, #\(off)]") }
    for i in stride(from: 0, to: 32, by: 2) {
      print("stp q\(i), q\(i+1), [sp, #\(F.vectors+i*16)]")
    }
    print("""
    mov x0, sp
    mrs x1, tpidr_el2
    cbz x1, .Lhalt
    bl tarwin_w1_dispatch_private
    cmp w0, #1
    b.ne .Lhalt
    """)
    for (reg, off) in banks where reg != "esr_el2" {
      print("ldr x9, [sp, #\(off)]\nmsr \(reg), x9")
    }
    for i in stride(from: 0, to: 32, by: 2) {
      print("ldp q\(i), q\(i+1), [sp, #\(F.vectors+i*16)]")
    }
    for i in stride(from: 0, to: 30, by: 2) {
      print("ldp x\(i), x\(i+1), [sp, #\(i*8)]")
    }
    print("""
    ldr x30, [sp, #240]
    add sp, sp, #\(F.size)
    eret

    // Only recover a current-EL read abort on this specific LDTR. Any
    // unrelated fault, including a store to broken kernel scratch, stops.
    .Lcopy_abort:
    stp x9, x10, [sp, #-16]!
    mrs x9, elr_el2
    adr x10, .Luser_load
    cmp x9, x10
    b.ne .Lhalt
    mrs x9, esr_el2
    ubfx x10, x9, #26, #6
    cmp x10, #0x25
    b.ne .Lhalt
    tst x9, #0x3c0
    b.ne .Lhalt
    and x10, x9, #63
    cmp x10, #0x11
    b.eq 2f
    cmp x10, #15
    b.hi .Lhalt
    2: adr x9, .Lload_failed
    msr elr_el2, x9
    ldp x9, x10, [sp], #16
    eret

    .global tarwin_w1_load_user_word
    tarwin_w1_load_user_word:
    mrs x2, CurrentEL
    cmp x2, #8
    b.ne .Lbad_mode
    mrs x2, hcr_el2
    tbz x2, #34, .Lbad_mode
    tbz x2, #27, .Lbad_mode
    mrs x2, id_aa64mmfr2_el1
    ubfx x2, x2, #4, #4
    cbz x2, 3f
    mrs x2, uao
    cbnz x2, .Lbad_mode
    3: mrs x2, id_aa64pfr1_el1
    ubfx x2, x2, #8, #4
    cmp x2, #2
    b.lo 4f
    mrs x3, tco
    msr tco, #0
    4:
    .Luser_load: ldtr x4, [x0]
    str x4, [x1]
    mov w0, #1
    b 5f
    .Lload_failed: mov w0, #0
    5: cmp x2, #2
    b.lo 6f
    msr tco, x3
    6: ret
    .Lbad_mode: mov w0, #0
    ret
    """)
  }
}
