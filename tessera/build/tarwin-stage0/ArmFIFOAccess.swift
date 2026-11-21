// Ordered MMIO for a caller-provisioned AArch64 Device mapping. No firmware
// call, DMA, interrupt or command-specific behavior is implemented in asm.
for bits in [8, 32, 64] {
  print("""
  define i\(bits) @tarwin_mmio_read\(bits)(ptr %p) nounwind {
    call void asm sideeffect "dmb osh", "~{memory}"()
    %v = load volatile i\(bits), ptr %p, align \(bits / 8)
    call void asm sideeffect "dmb osh", "~{memory}"()
    ret i\(bits) %v
  }
  """)
}
for bits in [8, 16, 32, 64] {
  print("""
define void @tarwin_mmio_write\(bits)(ptr %p, i\(bits) %v) nounwind {
  call void asm sideeffect "dmb osh", "~{memory}"()
  store volatile i\(bits) %v, ptr %p, align \(bits / 8)
  call void asm sideeffect "dmb osh", "~{memory}"()
  ret void
}
""")
}
print("""
define void @tarwin_publish_device_tables() nounwind {
  call void asm sideeffect "dsb oshst", "~{memory}"()
  ret void
}
""")

// Check a proposed high PCI page with the current hardware translation
// regime. Never change mappings or use an identity guess on a failed walk.
let walk = [
  "mrs x1, CurrentEL", "cmp x1, #8", "b.ne 1f", "mrs x2, PAR_EL1",
  "at s1e2w, x0", "isb", "mrs x0, PAR_EL1", "msr PAR_EL1, x2", "ret",
  "1: mov x0, #1", "ret",
]
print("""
define i64 @tarwin_cold_el2_write_translation(i64 %address) naked nounwind {
  call void asm sideeffect "\(walk.joined(separator: "\\0A"))", "~{memory}"()
  unreachable
}
""")
