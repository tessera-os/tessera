print("""
.text
.globl tarwin_rv_ticks
tarwin_rv_ticks:
  fence iorw, iorw
  rdtime a0
  fence iorw, iorw
  ret
.globl tarwin_rv_compare
tarwin_rv_compare:
  csrw 0x14d, a0  // stimecmp (RV64, one atomic write)
  li a0, 32
  csrs sie, a0
  ret
.globl tarwin_rv_disarm
tarwin_rv_disarm:
  li a0, 32
  csrc sie, a0
  li a0, -1
  csrw 0x14d, a0
  ret
""")
