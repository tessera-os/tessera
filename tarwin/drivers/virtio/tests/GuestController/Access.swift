// Prints LLVM IR for the probe's volatile register, barrier and UART access.
// Freestanding Swift has no volatile MMIO, x86 port-I/O or device barrier.
let arch = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
var ir = ""
for (bits, align) in [(8, 1), (16, 2), (32, 4), (64, 8)] {
  ir += """
    define i\(bits) @gc_load\(bits)(i64 %a) {
      %p = inttoptr i64 %a to ptr
      %v = load volatile i\(bits), ptr %p, align \(align)
      ret i\(bits) %v
    }
    define void @gc_store\(bits)(i64 %a, i\(bits) %v) {
      %p = inttoptr i64 %a to ptr
      store volatile i\(bits) %v, ptr %p, align \(align)
      ret void
    }

    """
}
let barrier: String
let uart: String
switch arch {
case "x86_64":
  barrier = "mfence"
  uart = """
      %s = call i8 asm sideeffect "inb %dx, $0", "={al},{dx},~{memory}"(i16 1021)
      %ready = and i8 %s, 32
    """
case "aarch64":
  barrier = "dsb sy"
  uart = """
      %s = load volatile i32, ptr inttoptr (i64 150994968 to ptr), align 4
      %ready = and i32 %s, 32
      %busy = icmp ne i32 %ready, 0
    """
case "riscv64":
  barrier = "fence iorw, iorw"
  uart = """
      %s = load volatile i8, ptr inttoptr (i64 268435461 to ptr), align 1
      %ready = and i8 %s, 32
    """
default:
  fatalError("usage: Access aarch64|x86_64|riscv64")
}
// Bounded transmit-ready poll: COM1 (q35), PL011 at 0x09000000 (Arm virt),
// 16550 at 0x10000000 (RISC-V virt). A stuck UART drops bytes, never hangs.
let busy = arch == "aarch64" ? "" : "  %busy = icmp eq i8 %ready, 0\n"
let send =
  arch == "x86_64"
  ? "  call void asm sideeffect \"outb $0, %dx\", \"{al},{dx},~{memory}\"(i8 %b, i16 1016)"
  : arch == "aarch64"
    ? "  store volatile i32 %w, ptr inttoptr (i64 150994944 to ptr), align 4"
    : "  store volatile i8 %b, ptr inttoptr (i64 268435456 to ptr), align 1"
ir += """
  define void @free(ptr %p) {
    ret void
  }
  define void @gc_barrier() {
    call void asm sideeffect "\(barrier)", "~{memory}"()
    ret void
  }
  define void @gc_uart(i8 %b) {
  entry:
    %w = zext i8 %b to i32
    br label %wait
  wait:
    %n = phi i32 [ 0, %entry ], [ %m, %wait ]
    %m = add i32 %n, 1
  \(uart)
  \(busy)  %more = icmp ult i32 %m, 1000000
    %again = and i1 %busy, %more
    br i1 %again, label %wait, label %send
  send:
  \(send)
    ret void
  }

  """
print(ir)
