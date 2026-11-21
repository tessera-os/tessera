print("""
.text
.global tarwin_psci_smc
tarwin_psci_smc:
  dsb sy
  smc #0
  isb
  ret
""")
