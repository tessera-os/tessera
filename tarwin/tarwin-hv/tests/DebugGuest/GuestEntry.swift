let arch = CommandLine.arguments[1]
print(".section .text.guest_entry,\"ax\"\n.global guest_start\nguest_start:")
switch arch {
case "arm":
  print(
    """
      mov x9,#0x110000
      mov sp,x9
      bl guest_kernel_main
      hvc #0x4b
    1: wfe
      b 1b
    """)
case "rv64":
  print(
    """
      .option norelax
      li sp,0x110000
      la gp,__global_pointer$
      mv a0,a1
      call guest_kernel_main
      ecall
    1: wfi
      j 1b
    """)
case "x64":
  print(
    """
      mov $0x110000,%rsp
      cld
      call guest_kernel_main
      vmmcall
    1: hlt
      jmp 1b
    """)
default: fatalError("unknown guest architecture")
}
