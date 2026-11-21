// Hosted emitter for operations not expressible in stage-0 Embedded Swift.
// Only linked into a single-CPU QEMU EL2 loader. UEFI has a physical
// identity map; after ExitBootServices there are no firmware calls or returns.
func naked(_ name: String, _ parameters: String, _ ops: [String]) {
  print("""
    define void @\(name)(\(parameters)) naked nounwind {
      call void asm sideeffect "\(ops.joined(separator: "\\0A"))", "~{memory}"()
      unreachable
    }
    """)
}

naked("tarboot_clean_range", "i64 %start, i64 %end", [
  "mrs x2, CTR_EL0", "ubfx x2, x2, #16, #4", "mov x3, #4", "lsl x2, x3, x2",
  "sub x3, x2, #1", "bic x0, x0, x3", "1: dc civac, x0",
  "add x0, x0, x2", "cmp x0, x1", "b.lo 1b", "dsb sy", "ret",
])
naked("tarboot_enter_arm", "i64 %tbib, i64 %entry, i64 %stack", [
  "msr daifset, #15", "dsb sy", "ic iallu", "dsb sy", "isb",
  "mrs x3, sctlr_el2", "bic x3, x3, #1", "bic x3, x3, #4", "bic x3, x3, #4096",
  "msr sctlr_el2, x3", "isb", "mov sp, x2", "mov x30, xzr", "br x1",
])

// Cold W1, single PE: make the privately staged instructions visible
// before creating RX leaves at their randomized virtual addresses.
naked("tarwin_w1_sync_rx", "i64 %start, i64 %end", [
  "mrs x2, CTR_EL0", "ubfx x2, x2, #16, #4", "mov x3, #4", "lsl x2, x3, x2",
  "sub x3, x2, #1", "bic x0, x0, x3", "1: dc cvau, x0",
  "add x0, x0, x2", "cmp x0, x1", "b.lo 1b", "dsb ish", "ic iallu", "dsb ish", "isb", "ret",
])
