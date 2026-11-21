// Ssaia indirect accesses are per-hart. Caller holds local IRQ exclusion.
print("""
.text
.globl tarwin_imsic_read
tarwin_imsic_read:
  csrrw t0, 0x150, a0
  csrr a0, 0x151
  csrw 0x150, t0
  ret
.globl tarwin_imsic_write
tarwin_imsic_write:
  csrrw t0, 0x150, a0
  csrw 0x151, a1
  csrw 0x150, t0
  ret
""")
