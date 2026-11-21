// Appended to the private x64 diagnostic. This integer-only bank and the
// VMCS aren't an ABI for running arbitrary guests on a shared host CPU.
print(
  """
  .text
  .code64
  .global vmx_msr, vmx_cr, vmx_activate, vmx_cmd, vmx_put, vmx_get, vmx_flush, vmx_enter
  vmx_msr:
    mov %edi,%ecx
    rdmsr
    shl $32,%rdx
    or %rdx,%rax
    ret
  vmx_cr:
    mov %cr0,%rax
    test %edi,%edi
    jz 1f
    mov %cr3,%rax
    cmp $3,%edi
    je 1f
    mov %cr4,%rax
  1: ret
  vmx_activate:
    mov %rdi,%cr0
    mov %rsi,%cr4
    lea test_tss(%rip),%rax
    lea tss_descriptor(%rip),%rcx
    movw $103,(%rcx)
    movw %ax,2(%rcx)
    shr $16,%rax
    movb %al,4(%rcx)
    movb $0x89,5(%rcx)
    movb %ah,7(%rcx)
    mov $24,%eax
    ltr %ax
    ret
  vmx_cmd:
    push %rsi
    test %edi,%edi
    jnz 1f
    vmxon (%rsp)
    jmp 4f
  1: cmp $1,%edi
    jne 2f
    vmclear (%rsp)
    jmp 4f
  2: cmp $2,%edi
    jne 3f
    vmptrld (%rsp)
    jmp 4f
  3: vmxoff
  4: seta %al
    pop %rsi
    movzbl %al,%eax
    ret
  vmx_put:
    vmwrite %rsi,%rdi
    seta %al
    movzbl %al,%eax
    ret
  vmx_get:
    vmread %rdi,%rax
    ja 1f
    mov $-1,%rax
  1: ret
  vmx_flush:
    push $0
    push %rdi
    mov $1,%eax
    invept (%rsp),%rax
    seta %al
    add $16,%rsp
    movzbl %al,%eax
    ret
  .global vmx_table_base
  vmx_table_base:
    lea gdt(%rip),%rax
    test %edi,%edi
    jz 1f
    lea test_tss(%rip),%rax
  1: ret
  vmx_enter:
  """)
let saved = ["rbx", "rbp", "r12", "r13", "r14", "r15"]
let regs = ["rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp"] + (8...15).map { "r" + String($0) }
for r in saved { print("push %" + r) }
print(
  """
  mov $0x6c14,%eax
  vmwrite %rsp,%rax
  jna vmx_failed
  lea vmx_exited(%rip),%rcx
  mov $0x6c16,%eax
  vmwrite %rcx,%rax
  jna vmx_failed
  test %edi,%edi
  """)
for (i, r) in regs.enumerated() { print("mov bank+\(8*i)(%rip),%\(r)") }
print(
  """
  jnz 1f
  vmlaunch
  jmp vmx_failed
  1: vmresume
  vmx_failed:
    xor %eax,%eax
    jmp vmx_return
  vmx_exited:
  """)
for (i, r) in regs.enumerated() { print("mov %\(r),bank+\(8*i)(%rip)") }
print("mov $1,%eax\nvmx_return:")
for r in saved.reversed() { print("pop %" + r) }
print("ret")
