// Produce immutable image backing and private, zero-initialized data
// frames in the monitor ELF. All addresses in the guest contract are GPAs.
let arch = CommandLine.arguments[1]
let page = arch == "arm" ? 16384 : 4096
let path = CommandLine.arguments[2]
guard !path.contains("\"") && !path.contains("\n") && !path.contains("\\") else {
  fatalError("bad image path")
}
print(
  """
  .text
  .global debug_layout, debug_putchar
  debug_layout:
  """)
switch arch {
case "arm":
  print("ldr x0,=layout\nret\ndebug_putchar:\nldr x1,=0x09000000\nstr w0,[x1]\nret\n.ltorg")
case "rv64":
  print("la a0,layout\nret\ndebug_putchar:\nli t0,0x10000000\nsb a0,0(t0)\nret")
case "x64":
  print(
    """
      lea layout(%rip),%rax
      ret
    debug_putchar:
      mov %edi,%ecx
      jmp serial_tx
    .global debug_rdi
    debug_rdi:
      mov %rdi,bank+32(%rip)
      ret
    """)
default: fatalError("unknown guest architecture")
}
if CommandLine.arguments.last == "metal" {
  print(".global debug_getchar\ndebug_getchar:")
  switch arch {
  case "arm":
    print("ldr x1,=0x09000000\n1: ldr w2,[x1,#24]\ntbnz w2,#4,1b\nldr w0,[x1]\nand w0,w0,#255\nret")
  case "rv64":
    print("li t0,0x10000000\n1: lbu a0,5(t0)\nandi a0,a0,1\nbeqz a0,1b\nlbu a0,0(t0)\nret")
  default:
    print(
      "mov $0x3fd,%dx\n1: in (%dx),%al\ntest $1,%al\njz 1b\nmov $0x3f8,%dx\nxor %eax,%eax\nin (%dx),%al\nret"
    )
  }
}
print(
  """
  .section .rodata
  .balign 8
  layout: .quad kernel_image,image_end-kernel_image,guest_stack,descriptor,screen,guest_ram
  .balign \(page)
  kernel_image: .incbin "\(path)"
  .balign \(page)
  image_end:
  descriptor: .quad 0x3147444b,\(page),0x400000,\(64*page),0x200000,16384
    .space \(page-48)
  .section .bss,"aw",%nobits
  .balign \(page)
  guest_stack: .space 65536
  screen: .space 16384
  guest_ram: .space \(64*page)
  """)
