// Privileged instructions: link into the kernel, never needed by the reader.
print("""
.text
.globl tarwin_clock_compare
tarwin_clock_compare:
  msr cntv_cval_el0, x0
  mov x0, #1
  msr cntv_ctl_el0, x0
  isb
  ret
.globl tarwin_clock_disarm
tarwin_clock_disarm:
  msr cntv_ctl_el0, xzr
  isb
  ret
""")
