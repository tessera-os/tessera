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
print("""
define void @tarwin_mmio_write8(ptr %p, i8 %v) nounwind {
  call void asm sideeffect "dmb osh", "~{memory}"()
  store volatile i8 %v, ptr %p, align 1
  call void asm sideeffect "dmb osh", "~{memory}"()
  ret void
}
""")
