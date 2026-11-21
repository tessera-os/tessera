// Standalone debug-QEMU boot CPU at EL2. Stage the VHE host MMU with RX
// kernel text, NX private writable tables/stack, one user-readable page,
// one missing page and one privileged-only page. No W1 archive or entry.
print("""
.section .text.boot,"ax"
.globl _start
_start:
  mrs x0, CurrentEL
  cmp x0, #8
  b.ne failed
  msr daifset, #15
  msr spsel, #1
  ldr x0, =stack_top
  mov sp, x0
  mov x0, #1
  lsl x0, x0, #34
  orr x0, x0, #(1 << 31)
  orr x0, x0, #(1 << 27)
  msr hcr_el2, x0
  isb
  ldr x0, =tarwin_w1_vectors
  msr vbar_el2, x0
  ldr x0, =root
  msr ttbr0_el2, x0
  msr ttbr1_el2, xzr
  ldr x0, =0x57590b510
  msr tcr_el2, x0
  mov x0, #255
  msr mair_el2, x0
  dsb sy
  isb
  tlbi alle2
  dsb sy
  isb
  mrs x0, sctlr_el2
  orr x0, x0, #1
  msr sctlr_el2, x0
  isb
  bl tarwin_vhe_copy_probe
  cbnz w0, failed
  adr x1, ok
  mov x0, #4
  hlt #0xf000
  adr x1, exit_ok
  b exit_host
.globl tarwin_w1_dispatch_private
tarwin_w1_dispatch_private:
failed:
  adr x1, bad
  mov x0, #4
  hlt #0xf000
  adr x1, exit_bad
exit_host:
  mov x0, #0x20
  hlt #0xf000
  b .
ok: .asciz "VHE-COPY-READ-WRITE-ABORT-DENY\\n"
bad: .asciz "VHE-COPY-FAILED\\n"
.p2align 3
exit_ok: .quad 0x20026,0
exit_bad: .quad 0x20026,1

.data
.p2align 14
root: .quad l1+3
.p2align 14
l1: .quad l2+3
.p2align 14
l2: .space 32*8
    .quad ktext+3
    .space (128-33)*8
    .quad user+3
.p2align 14
ktext: .space 32*8
  .quad 0x0040000040080783,0x0040000040084783
""")
// Bootstrap code and data occupy disjoint 16 KiB pages. Keep the user
// sample at PA 0x40200000 outside this privileged identity mapping.
for i in 34..<128 {
  let pa: UInt64 = 0x4000_0000 + UInt64(i)*16384
  print(".quad 0x" + String(pa | 0x0060_0000_0000_0703, radix: 16))
}
print("""
.p2align 14
user: .quad 0x0060000040200fc3,0,0x0060000040204783,0x0060000040208f43
.p2align 14
  .space 65536
stack_top:
.section .sample,"a"
.quad 0x1234,0x5678
.space 16384-24
.quad 0xfeed
.quad 0xcafe
""")
