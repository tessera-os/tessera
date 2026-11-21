// Hosted Swift stage-0 bridge for the boot CPU's VHE EL2/0 exception
// regime. The caller provisions the guarded SP_EL2, private per-CPU context,
// host FP access, process keys, and immutable high-half code before use.
// Boot CPU only. No scheduling, SVE/SME, interrupts, or EL1 guest exits.
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
    mrs x9, vbar_el2
    adr x10, .Lslice_vectors
    cmp x9, x10
    b.eq .Lslice_trap
    mov x0, sp
    mrs x1, tpidr_el2
    cbz x1, .Lhalt
    bl tarwin_w1_dispatch_private
    .global tarwin_w1_finish_private
    tarwin_w1_finish_private:
    cmp w0, #1
    b.eq .Lresume
    cmp w0, #2
    b.ne .Lhalt
    // Look up the captured caller in per-CPU state. Return a checked top
    // in the same TTBR1; zero means there is no safe scheduler stack.
    msr daifset, #15
    // Do not leave a supervisor control stack attached to the dying
    // thread. Paired SP/GCSPR switching is not provided by this ABI.
    mrs x9, id_aa64pfr1_el1
    ubfx x9, x9, #44, #4
    cbz x9, .Lno_supervisor_gcs
    cmp x9, #1
    b.ne .Lhalt
    .arch_extension gcs
    mrs x9, gcscr_el2
    cbnz x9, .Lhalt
    .Lno_supervisor_gcs:
    mrs x0, tpidr_el2
    mov x1, sp
    mrs x2, ttbr1_el2
    bl tarwin_w1_stop_stack_top
    mov x9, #0xffff800000000000
    cmp x0, x9
    b.lo .Lhalt
    tst x0, #15
    b.ne .Lhalt
    mov sp, x0
    mov x29, xzr
    mov x30, xzr
    clrex
    mrs x0, tpidr_el2
    mov x1, sp
    mrs x2, ttbr1_el2
    bl tarwin_w1_stopped_private
    b .Lhalt
    .Lresume:
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

    // Match the fault PC and its access direction. In particular a store
    // to broken kernel scratch after a successful LDTR is not recoverable.
    .Lcopy_abort:
    stp x9, x10, [sp, #-16]!
    mrs x9, elr_el2
    adr x10, .Luser_load
    cmp x9, x10
    b.eq .Lread_abort
    adr x10, .Luser_store
    cmp x9, x10
    b.ne .Lhalt
    mrs x9, esr_el2
    tbz x9, #6, .Lhalt
    b .Lcheck_abort
    .Lread_abort:
    mrs x9, esr_el2
    tbnz x9, #6, .Lhalt
    .Lcheck_abort:
    ubfx x10, x9, #26, #6
    cmp x10, #0x25
    b.ne .Lhalt
    tst x9, #0x380
    b.ne .Lhalt
    and x10, x9, #63
    cmp x10, #0x11
    b.eq 2f
    cmp x10, #15
    b.hi .Lhalt
    2: adr x9, .Lcopy_failed
    msr elr_el2, x9
    ldp x9, x10, [sp], #16
    eret

    .global tarwin_w1_load_user_word
    tarwin_w1_load_user_word:
    mov w5, #0
    b .Luser_access
    .global tarwin_w1_store_user_word
    tarwin_w1_store_user_word:
    mov w5, #1
    .Luser_access:
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
    cbnz w5, .Luser_store
    .Luser_load: ldtr x4, [x0]
    str x4, [x1]
    b .Lcopied
    .Luser_store: sttr x1, [x0]
    .Lcopied: mov w0, #1
    b 5f
    .Lcopy_failed: mov w0, #0
    5: cmp x2, #2
    b.lo 6f
    msr tco, x3
    6: ret
    .Lbad_mode: mov w0, #0
    ret

    // Boot CPU only, ASID zero, immutable TTBR1. The caller owns both
    // finished roots and the current CPU, with DAIF masked until its new
    // private process context is installed. Never return through the old map.
    .global tarwin_w1_switch_user_root
    tarwin_w1_switch_user_root:
    mov w4, #0
    b .Lswitch_root
    .global tarwin_w1_switch_guarded_root
    tarwin_w1_switch_guarded_root:
    mov w4, #1
    .Lswitch_root:
    mrs x2, CurrentEL
    cmp x2, #8
    b.ne .Lbad_mode
    mrs x2, hcr_el2
    tbz x2, #34, .Lbad_mode
    tbz x2, #27, .Lbad_mode
    mrs x2, sctlr_el2
    tbz x2, #0, .Lbad_mode
    tbnz x2, #61, .Lbad_mode // DAIF alone does not mask superpriority IRQs
    mrs x2, spsel
    cbz x2, .Lbad_mode
    mrs x2, daif
    and x2, x2, #0x3c0
    cmp x2, #0x3c0
    b.ne .Lbad_mode
    mrs x2, pan
    cbz x2, .Lbad_mode
    cbz x0, .Lbad_mode
    cbz x1, .Lbad_mode
    cmp x0, x1
    b.eq .Lbad_mode
    orr x2, x0, x1
    tst x2, #0x3fff
    b.ne .Lbad_mode
    lsr x2, x2, #48
    cbnz x2, .Lbad_mode
    mrs x2, ttbr1_el2
    cmp x2, x1
    b.ne .Lbad_mode
    mrs x2, tcr_el2
    ldr x3, =0x57510b510
    cmp x2, x3
    b.ne .Lbad_mode
    // Root switching does not change the global meaning of a PTE.
    // The typed caller has finished both roots for the same encoding.
    mrs x2, S3_0_C0_C7_3 // ID_AA64MMFR3_EL1
    and x3, x2, #15      // TCRX
    cbnz w4, .Lguarded
    cbz x3, .Lpermissions_ok
    cmp x3, #1
    b.ne .Lbad_mode
    mrs x2, S3_4_C2_C0_3 // TCR2_EL2
    cbnz x2, .Lbad_mode
    b .Lpermissions_ok
    .Lguarded:
    cmp x3, #1
    b.ne .Lbad_mode
    ubfx x2, x2, #8, #4 // S1PIE
    cmp x2, #1
    b.ne .Lbad_mode
    mrs x2, id_aa64pfr1_el1
    ubfx x2, x2, #44, #4
    cmp x2, #1
    b.ne .Lbad_mode
    mrs x2, S3_4_C2_C0_3 // TCR2_EL2
    cmp x2, #2
    b.ne .Lbad_mode
    mrs x2, S3_4_C10_C2_3 // PIR_EL2
    ldr x3, =\(ArmPermissionLayout.pir)
    cmp x2, x3
    b.ne .Lbad_mode
    mrs x2, S3_4_C10_C2_2 // PIRE0_EL2
    ldr x3, =\(ArmPermissionLayout.pire0)
    cmp x2, x3
    b.ne .Lbad_mode
    .Lpermissions_ok:
    mrs x2, mair_el2
    and x2, x2, #255
    cmp x2, #255
    b.ne .Lbad_mode
    mov x3, #0xffff800000000000
    adr x2, .
    cmp x2, x3
    b.lo .Lbad_mode
    cmp x30, x3
    b.lo .Lbad_mode
    mov x2, sp
    cmp x2, x3
    b.lo .Lbad_mode
    mrs x2, vbar_el2
    cmp x2, x3
    b.lo .Lbad_mode
    mrs x2, tpidr_el2
    cmp x2, x3
    b.lo .Lbad_mode
    dsb ishst
    msr ttbr0_el2, x0
    isb
    tlbi alle2is
    dsb ish
    isb
    mov w0, #1
    ret

    // Boot CPU, verified import only. x2 is the aligned IA pair borrowed
    // from the unpublished child's protected key bank, x3 its owner's
    // expected host TTBR1. Never accept these arguments from a user trap.
    .global tarwin_w1_sign_private_import
    .hidden tarwin_w1_sign_private_import
    tarwin_w1_sign_private_import:
    bti c
    mrs x4, CurrentEL
    cmp x4, #8
    b.ne .Lbad_mode
    mrs x4, hcr_el2
    tbz x4, #34, .Lbad_mode
    tbz x4, #27, .Lbad_mode
    mrs x4, sctlr_el2
    tbz x4, #0, .Lbad_mode
    tbz x4, #31, .Lbad_mode // IA must already be enabled
    tbnz x4, #61, .Lbad_mode // DAIF alone cannot exclude a superpriority IRQ
    tbnz x4, #25, .Lbad_mode // little-endian key record
    mrs x4, daif
    and x4, x4, #0x3c0
    cmp x4, #0x3c0
    b.ne .Lbad_mode
    mrs x4, pan
    cbz x4, .Lbad_mode
    mrs x4, ttbr1_el2
    cbz x3, .Lbad_mode
    cmp x4, x3
    b.ne .Lbad_mode
    mrs x4, tcr_el2
    ldr x5, =0x57510b510
    cmp x4, x5
    b.ne .Lbad_mode
    mov x4, #0xffff800000000000
    adr x5, .
    cmp x5, x4
    b.lo .Lbad_mode
    cmp x2, x4
    b.lo .Lbad_mode
    tst x2, #7
    b.ne .Lbad_mode
    // Both the code target and the storage address in the modifier must
    // fit the W1 image window. The verified loader checks their exact RVAs.
    ubfx x4, x1, #0, #48
    tst x4, #7
    b.ne .Lbad_mode
    tst x0, #3
    b.ne .Lbad_mode
    mov x5, #0x100000000
    cmp x0, x5
    b.lo .Lbad_mode
    cmp x4, x5
    b.lo .Lbad_mode
    orr x4, x4, x0
    lsr x4, x4, #43
    cbnz x4, .Lbad_mode
    // Load both halves before changing the key. No calls, stack, memory
    // accesses or indirect branches while the child key is installed.
    .arch_extension pauth
    ldp x4, x5, [x2]
    mrs x6, APIAKeyLo_EL1
    mrs x7, APIAKeyHi_EL1
    msr APIAKeyLo_EL1, x4
    msr APIAKeyHi_EL1, x5
    isb
    pacia x0, x1
    msr APIAKeyLo_EL1, x6
    msr APIAKeyHi_EL1, x7
    isb
    mov x4, xzr
    mov x5, xzr
    mov x6, xzr
    mov x7, xzr
    ret
    """)
    emitArmGuardedSlice()
  }
}
