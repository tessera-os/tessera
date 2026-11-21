// Debug BIOS handoff for the PVH monitor loaded in private emulator RAM.
// The diagnostic never changes a locked firmware policy.
guard CommandLine.arguments.count == 3,
  let bytes = Int(CommandLine.arguments[2]), (1...262144).contains(bytes),
  let entry = UInt32(CommandLine.arguments[1], radix: 16),
  (0x100000..<0x200000).contains(entry)
else { fatalError("invalid PVH entry") }
print(
  """
  .text
  .code16
  .global boot
  boot:
    cli
    xor %ax,%ax
    mov %ax,%ds
    mov %ax,%ss
    mov $0x7c00,%sp
    movb %dl,drive
    mov $0x2000,%ax
    mov %ax,%es
    sti
  sector:
    mov index,%ax
    xor %dx,%dx
    mov $18,%bx
    div %bx
    mov %dl,%cl
    inc %cl
    xor %dx,%dx
    mov $2,%bx
    div %bx
    mov %dl,%dh
    mov drive,%dl
    mov %al,%ch
    xor %bx,%bx
    mov $0x0201,%ax
    int $0x13
    jc disk_failed
    mov %es,%ax
    add $32,%ax
    mov %ax,%es
    incw index
    cmpw $\((bytes+511)/512+1),index
    jb sector
    cli
    in $0x92,%al
    or $2,%al
    out %al,$0x92
    lgdt descriptor
    mov %cr0,%eax
    or $1,%eax
    mov %eax,%cr0
    ljmpl $8,$protected
  .code32
  protected:
    mov $16,%ax
    mov %ax,%ds
    mov %ax,%ss
    mov %ax,%es
    mov $0x70000,%esp
    cld
    mov $0x20000,%esi
    mov $0x100000,%edi
    mov $\((bytes+3)/4),%ecx
    rep movsl
    xor %eax,%eax
    mov $65536,%ecx
    rep stosl
    mov $1,%eax
    cpuid
    test $0x20,%ecx
    jz 1f
    mov $0x3a,%ecx
    rdmsr
    test $1,%al
    jnz 1f
    or $5,%al
    wrmsr
  1: mov $\(entry),%eax
    jmp *%eax
  .code16
  disk_failed: cli
    hlt
    jmp disk_failed
  drive: .byte 0
  index: .word 1
  .balign 8
  table: .quad 0,0x00cf9a000000ffff,0x00cf92000000ffff
  descriptor: .word 23
    .long table
  .org 510
  .word 0xaa55
  """)
