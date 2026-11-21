// Test-only EL2 observer. Install an inactive EL1/0 regime and use the
// hardware page walker without executing or dereferencing any EL0 address.
// Single CPU, after firmware exit; restore every changed system register.
import Foundation

let code = """
mrs x3, CurrentEL
cmp x3, #8
b.ne 9f
mrs x3, hcr_el2
tbnz x3, #34, 9f
tbnz x3, #12, 9f
tbnz x3, #0, 9f
mrs x4, daif
msr daifset, #15
bic x10, x3, #(1 << 27)
orr x10, x10, #(1 << 31)
msr hcr_el2, x10
isb
mrs x5, ttbr0_el1
mrs x13, ttbr1_el1
mrs x6, tcr_el1
mrs x7, mair_el1
mrs x8, sctlr_el1
mrs x9, par_el1
bic x10, x8, #1
msr sctlr_el1, x10
isb
dsb sy
tlbi vmalle1
dsb sy
isb
msr ttbr0_el1, x0
msr ttbr1_el1, x11
mov x10, #0xb510
movk x10, #0x7510, lsl #16
movk x10, #5, lsl #32
msr tcr_el1, x10
mov x10, #255
msr mair_el1, x10
isb
orr x10, x8, #1
bic x10, x10, #(1 << 25)
msr sctlr_el1, x10
isb
at s1e0r, x1
isb
mrs x10, par_el1
str x10, [x2]
at s1e0w, x1
isb
mrs x10, par_el1
str x10, [x2, #8]
add x1, x1, #4, lsl #12
at s1e0w, x1
isb
mrs x10, par_el1
str x10, [x2, #16]
add x1, x1, #4, lsl #12
at s1e0r, x1
isb
mrs x10, par_el1
str x10, [x2, #80]
at s1e0w, x1
isb
mrs x10, par_el1
str x10, [x2, #88]
add x1, x1, #4, lsl #12
at s1e0r, x1
isb
mrs x10, par_el1
str x10, [x2, #24]
at s1e1r, x12
isb
mrs x10, par_el1
str x10, [x2, #32]
at s1e1w, x12
isb
mrs x10, par_el1
str x10, [x2, #40]
at s1e0r, x12
isb
mrs x10, par_el1
str x10, [x2, #48]
add x12, x12, #4, lsl #12
at s1e1w, x12
isb
mrs x10, par_el1
str x10, [x2, #56]
at s1e0w, x12
isb
mrs x10, par_el1
str x10, [x2, #64]
add x12, x12, #4, lsl #12
at s1e1r, x12
isb
mrs x10, par_el1
str x10, [x2, #72]
bic x10, x8, #1
msr sctlr_el1, x10
isb
tlbi vmalle1
dsb sy
isb
msr ttbr0_el1, x5
msr ttbr1_el1, x13
msr tcr_el1, x6
msr mair_el1, x7
isb
msr sctlr_el1, x8
msr par_el1, x9
msr hcr_el2, x3
isb
msr daif, x4
mov x0, #1
ret
9: mov x0, #0
ret
"""
print("""
define i64 @tarboot_test_translation(i64 %root, i64 %va, ptr %results, i64 %kroot, i64 %kva) naked nounwind {
  call void asm sideeffect "mov x11, x3\\0Amov x12, x4\\0A\(code.replacingOccurrences(of: "\n", with: "\\0A"))", "~{memory}"()
  unreachable
}
""")

// Boot-CPU-only EL2 diagnostic. Sign or authenticate without branching to the
// address. Save the current IA key and control state entirely in registers.
for (name, instruction) in [("sign", "pacia"), ("auth", "autia")] {
  let ops = [
    ".arch_extension pauth", "mrs x4, daif", "msr daifset, #15",
    "mrs x5, APIAKeyLo_EL1", "mrs x6, APIAKeyHi_EL1", "mrs x7, sctlr_el2",
    "msr APIAKeyLo_EL1, x2", "msr APIAKeyHi_EL1, x3",
    "orr x8, x7, #(1 << 31)", "msr sctlr_el2, x8", "isb",
    "\(instruction) x0, x1", "msr APIAKeyLo_EL1, x5", "msr APIAKeyHi_EL1, x6",
    "msr sctlr_el2, x7", "isb", "mov x2, xzr", "mov x3, xzr",
    "mov x5, xzr", "mov x6, xzr", "msr daif, x4", "ret",
  ]
  print("""
  define i64 @tarboot_test_\(name)_ia(i64 %ptr, i64 %modifier, i64 %lo, i64 %hi) naked nounwind {
    call void asm sideeffect "\(ops.joined(separator: "\\0A"))", "~{memory}"()
    unreachable
  }
  """)
}
