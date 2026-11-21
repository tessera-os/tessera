// QEMU virt, one hart, one allocated supervisor guest interrupt file.
print(
  """
  .text
  .option norelax
  .option norvc
  .global irq_prepare, irq_post, irq_ticks, irq_timer
  irq_ticks: rdtime a0
    ret
  irq_prepare:
    csrw htimedelta,a0
    li t0,2
    csrs hcounteren,t0
    li t0,1<<63
    csrs henvcfg,t0
    li t0,-1
    csrw 0x24d,t0
    slli a1,a1,12
    csrs hstatus,a1
    csrr t0,hstatus
    li t1,0x3f000
    and t0,t0,t1
    bne t0,a1,1f
    li t0,(1<<10)|(1<<6)
    csrs hideleg,t0
    li a0,1
    ret
  1: li a0,0
    ret
  irq_post:
    fence iorw,iorw
    sw a1,0(a0)
    fence iorw,iorw
    ret
  irq_timer: csrr a0,0x24d
    ret
  .balign 4096
  irq_guest:
    li s1,0x200000
    la t0,guest_trap
    csrw stvec,t0
    // Enable identity 37, threshold zero and delivery in our own VS file.
    li t0,0xc0
    csrw 0x150,t0
    li t1,1<<37
    csrw 0x151,t1
    li t0,0x72
    csrw 0x150,t0
    csrw 0x151,zero
    li t0,0x70
    csrw 0x150,t0
    li t1,1
    csrw 0x151,t1
    li t0,(1<<9)|(1<<5)
    csrw sie,t0
    rdtime t0
    sd t0,0(s1)
    li a0,0x71
    ecall
    ld t1,8(s1)
    bnez t1,bad_irq
    csrsi sstatus,2
  1: ld t0,8(s1)
    beqz t0,1b
    li t1,1
    bne t0,t1,bad_irq
    // A VS-mode stimecmp write targets vstimecmp; expiry delegates VSTIP.
    rdtime t0
    addi t0,t0,1024
    csrw 0x14d,t0
  2: ld t0,8(s1)
    beq t0,t1,2b
    li t1,2
    bne t0,t1,bad_irq
    li a0,0x73
    ecall
  bad_irq: li a0,0xff
    ecall
    j bad_irq
  .balign 4
  guest_trap:
    // t3-t6 are reserved to this handler.
    csrr t3,scause
    bgez t3,bad_irq
    slli t3,t3,1
    srli t3,t3,1
    li t4,9
    bne t3,t4,3f
    csrrw t5,0x15c,zero
    srli t5,t5,16
    sd t5,16(s1)
    csrr t5,0x15c
    bnez t5,bad_irq
    j 4f
  3: li t4,5
    bne t3,t4,bad_irq
    li t5,-1
    csrw 0x14d,t5
    sd t3,24(s1)
  4: ld t6,8(s1)
    addi t6,t6,1
    sd t6,8(s1)
    sret
  .balign 4096
  """)
