let kernel = CommandLine.arguments.dropFirst().first == "kernel"
// Dedicated QEMU PVH test image, not a host context switch. All segment,
// GPR and control inputs below are private, fixed state of a trusted guest.
let intel = CommandLine.arguments.dropFirst().first == "vmx"
print(
  """
  .section .note.Xen,"a",@note
  .p2align 2
  .long 4,4,18
  .asciz "Xen"
  .long _start
  .section .text.entry,"ax"
  .code32
  .global _start
  _start:
    cli
    cld
    lgdt gdtr
    movl $host_l4,%eax
    movl %eax,%cr3
    movl %cr4,%eax
    orl $0x620,%eax
    movl %eax,%cr4
    movl $0xc0000080,%ecx
    rdmsr
    orl $\(intel ? "0x900" : "0x1900"),%eax
    wrmsr
    movl %cr0,%eax
    andl $~4,%eax
    orl $0x80010001,%eax
    movl %eax,%cr0
    ljmp $8,$long_entry
  .code64
  long_entry:
    movw $16,%ax
    movw %ax,%ds
    movw %ax,%es
    movw %ax,%ss
    lea stack_top(%rip),%rsp
    mov $0x3fb,%dx
    mov $3,%al
    out %al,(%dx)
  """)
if intel {
  print(
    """
      mov $1,%eax
      cpuid
      test $0x20,%ecx
      jz unavailable
      lea arena(%rip),%rdi
      lea guest_page(%rip),%rsi
      lea data_page(%rip),%rdx
      lea guest_tables(%rip),%rcx
      lea vmcb(%rip),%r8
      lea hsave(%rip),%r9
      call run_vmx_probe
      jmp result
    unavailable:
      lea unavailable_string(%rip),%rsi
      jmp report
    unavailable_string: .asciz "VMX UNAVAILABLE\\n"
    """)
} else {
  print(
    """
      mov $0x8000000a,%eax
      cpuid
      test $1,%edx
      jz fail
      mov $0xc0010117,%ecx
      lea hsave(%rip),%rax
      xor %edx,%edx
      wrmsr
      lea arena(%rip),%rdi
      lea guest_page(%rip),%rsi
      lea data_page(%rip),%rdx
      lea guest_tables(%rip),%rcx
      lea vmcb(%rip),%r8
      call run_npt_probe
    """)
}
print(
  """
  result:
    test %eax,%eax
    jz fail
    lea pass_string(%rip),%rsi
    jmp report
  fail:
    lea fail_string(%rip),%rsi
  report:
  1: lodsb
     test %al,%al
     jz 2f
     mov %al,%cl
     call serial_tx
     jmp 1b
  2: hlt
     jmp 2b
  serial_tx:
     mov $0x3fd,%dx
  3: in (%dx),%al
     test $0x20,%al
     jz 3b
     mov $0x3f8,%dx
     mov %cl,%al
     out %al,(%dx)
     ret
  pass_string: .asciz "TARWIN \(kernel ? "DEBUG CONSOLE" : intel ? "X64 EPT" : "X64 NPT") PASS\\n"
  fail_string: .asciz "TARWIN X64 \(intel ? "EPT" : "NPT") FAIL\\n"

  .global npt_enter
  .global x64_spills
  x64_spills:
    lea bank(%rip),%rax
    ret
  npt_enter:
    // RAX, RIP, RSP, RFLAGS and control state travel in VMCB/HSAVE;
    // the remaining guest GPRs use this private per-vCPU spill bank.
  """)
let preserved = ["rbx", "rbp", "r12", "r13", "r14", "r15"]
let regs = ["rbx", "rcx", "rdx", "rsi", "rdi", "rbp"] + (8...15).map { "r" + String($0) }
for r in preserved { print("push %" + r) }
print("lea vmcb(%rip),%rax")
for (i, r) in regs.enumerated() { print("mov bank+\(8*i)(%rip),%\(r)") }
print("vmrun %rax")
for (i, r) in regs.enumerated() { print("mov %\(r),bank+\(8*i)(%rip)") }
for r in preserved.reversed() { print("pop %" + r) }
print(
  """
    ret
  .balign 4096
  guest_page:
    mov $0x200000,%ebx
    mov $0x5347,%eax
    mov %rax,(%rbx)
    \(intel ? "vmcall" : "vmmcall")
    lea (%rsi,%r15),%r11
    \(intel ? "vmcall" : "vmmcall")
    mov $0xdead,%eax
  guest_write:
    mov %rax,(%rbx)
  guest_read:
    mov (%rbx),%rcx
  guest_exec:
    jmp *%rbx
  .balign 4096
  .global npt_next
  npt_next:
    // Only the two known fixture instructions may be skipped.
    cmp $(0x10000+guest_write-guest_page),%rdi
    jne 1f
    mov $(0x10000+guest_read-guest_page),%eax
    ret
  1: cmp $(0x10000+guest_read-guest_page),%rdi
     jne 2f
     mov $(0x10000+guest_exec-guest_page),%eax
     ret
  2: xor %eax,%eax
     ret
  .balign 8
  gdt: .quad 0,0x00af9a000000ffff,0x00cf92000000ffff
  tss_descriptor: .quad 0,0
  gdtr: .word 39
        .long gdt
  .section .data,"aw"
  .balign 4096
  host_l4: .quad host_l3+7
  .balign 4096
  host_l3: .quad host_l2+7
  .balign 4096
  host_l2:
  """)
for i in 0..<512 { print(".quad \(i*0x200000+0x83)") }
print(
  """
  .section .bss,"aw",@nobits
  .balign 4096
  arena: .skip \(kernel ? 65536 : 32768)
  guest_tables: .skip 12288
  data_page: .skip 4096
  vmcb: .skip 4096
  hsave: .skip 4096
  bank: .skip 128
  test_tss: .skip 104
  .balign 16
  .skip 32768
  stack_top:
  """)
