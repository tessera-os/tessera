// One dedicated EL2 core, one stopped vCPU. No physical IRQ forwarding.
print(
  """
  .text
  .global irq_prepare, irq_empty, irq_write, irq_timer, irq_ticks
  irq_ticks: isb
    mrs x0,cntpct_el0
    ret
  irq_prepare:
    mrs x1,icc_sre_el2
    orr x1,x1,#8
    orr x1,x1,#1
    msr icc_sre_el2,x1
    isb
    msr ich_hcr_el2,xzr
    msr ich_lr0_el2,xzr
    mov x1,#2
    movk x1,#0xff00,lsl #16
    msr ich_vmcr_el2,x1
    mov x1,#1
    msr ich_hcr_el2,x1
    msr cntvoff_el2,x0
    mrs x1,hcr_el2
    orr x1,x1,#(1<<4)
    msr hcr_el2,x1
    isb
    ret
  irq_empty: mrs x0,ich_elrsr_el2
    ret
  irq_write: msr ich_lr0_el2,x0
    isb
    ret
  irq_timer: mrs x0,cntv_ctl_el02
    ret
  .balign 16384
  irq_guest:
    mov x19,#0x200000
    adr x0,guest_vectors
    msr vbar_el1,x0
    isb
    mov x0,#0xff
    msr icc_pmr_el1,x0
    mov x0,#1
    msr icc_igrpen1_el1,x0
    msr cntv_ctl_el0,xzr
    isb
    mrs x0,cntvct_el0
    str x0,[x19]
    hvc #0x71
    // IRQ masked on entry; pending SPI must wait for DAIF.I to clear.
    ldr x1,[x19,#8]
    cbnz x1,bad_irq
    msr daifclr,#2
    isb
  1: ldr x1,[x19,#8]
    cbz x1,1b
    cmp x1,#1
    b.ne bad_irq
    mrs x0,cntvct_el0
    add x0,x0,#1024
    msr cntv_cval_el0,x0
    mov x1,#1
    msr cntv_ctl_el0,x1
    isb
  2: mrs x1,cntv_ctl_el0
    tbz x1,#2,2b
    hvc #0x72
  3: ldr x1,[x19,#8]
    cmp x1,#2
    b.lo 3b
    b.ne bad_irq
    hvc #0x73
  bad_irq: hvc #0xff
    b bad_irq
  .balign 2048
  guest_vectors:
  """)
for i in 0..<16 { print("b " + (i == 5 ? "handle_irq" : "bad_irq") + "\n.space 124") }
print(
  """
  handle_irq:
    // Dedicated guest handlers reserve x14-x16; interrupted code never uses them.
    mrs x14,icc_iar1_el1
    cmp x14,#1020
    b.hs bad_irq
    ldr x15,[x19,#8]
    cmp x15,#2
    b.hs bad_irq
    add x16,x19,#16
    str x14,[x16,x15,lsl #3]
    add x15,x15,#1
    str x15,[x19,#8]
    cmp x14,#27
    b.ne 1f
    msr cntv_ctl_el0,xzr
    isb
  1: msr icc_eoir1_el1,x14
    isb
    eret
  .balign 16384
  """)
