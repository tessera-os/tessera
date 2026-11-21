// Ordered MMIO for a caller-provisioned AArch64 Device mapping. No firmware
// call, DMA, interrupt or command-specific behavior is implemented in asm.
for bits in [8, 32] {
  print("""
  define i\(bits) @tarwin_mmio_read\(bits)(ptr %p) nounwind {
    call void asm sideeffect "dmb osh", "~{memory}"()
    %v = load volatile i\(bits), ptr %p, align \(bits / 8)
    call void asm sideeffect "dmb osh", "~{memory}"()
    ret i\(bits) %v
  }
  """)
}
for bits in [8, 16, 32] {
  print("""
define void @tarwin_mmio_write\(bits)(ptr %p, i\(bits) %v) nounwind {
  call void asm sideeffect "dmb osh", "~{memory}"()
  store volatile i\(bits) %v, ptr %p, align \(bits / 8)
  call void asm sideeffect "dmb osh", "~{memory}"()
  ret void
}
""")
}
