// BASE probe_extension and HSM hart_get_status/start/stop. Never interpret
// sbiret.value if sbiret.error is nonzero. Successful hart_stop cannot return.
print("""
.text
.global tarwin_sbi_hsm_present
tarwin_sbi_hsm_present:
  li a0, 0x48534d
  li a7, 16
  li a6, 3
  ecall
  seqz a0, a0
  snez a1, a1
  and a0, a0, a1
  ret
.global tarwin_sbi_hsm_status
tarwin_sbi_hsm_status:
  li a7, 0x48534d
  li a6, 2
  ecall
  bnez a0, 1f
  mv a0, a1
  ret
1: li a0, -1
  ret
.global tarwin_sbi_hsm_start
tarwin_sbi_hsm_start:
  fence rw, rw
  li a7, 0x48534d
  li a6, 0
  ecall
  ret
.global tarwin_sbi_hsm_stop
tarwin_sbi_hsm_stop:
  fence rw, rw
  li a7, 0x48534d
  li a6, 1
  ecall
  ret
""")
