// Instruction veneer shared by the EL0 reader and the kernel publisher.
// Complete earlier memory reads before sampling and don't let later reads
// issue before the sample. CNTFRQ is supplied by the calibrated platform.
print("""
.text
.globl tarwin_clock_ticks
tarwin_clock_ticks:
  dsb ishld
  isb
  mrs x0, cntvct_el0
  isb
  ret
.globl tarwin_clock_hz
tarwin_clock_hz:
  mrs x0, cntfrq_el0
  ret
""")
