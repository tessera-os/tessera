// Diagnostic only. Fixed MSR bank and QEMU debug port; no raw-MSR ABI.
print("""
define void @mca_cpuid(i32 %leaf, ptr %out) {
  %r = call {i32,i32,i32,i32} asm sideeffect "cpuid", "={ax},={bx},={cx},={dx},0,2,~{memory}"(i32 %leaf, i32 0)
  store {i32,i32,i32,i32} %r, ptr %out, align 4
  ret void
}
define void @mca_note(i8 %byte) {
  call void asm sideeffect "outb $0, $$0xe9", "{al},~{memory}"(i8 %byte)
  ret void
}
define void @mca_clear() {
  call void asm sideeffect "wrmsr", "{ax},{dx},{cx},~{memory}"(i32 0, i32 0, i32 1041)
  ret void
}
""")
for (name, n) in [("cap", 0x179), ("status", 0x411), ("addr", 0x412), ("misc", 0x413)] {
  print("""
  define i64 @mca_\(name)() {
    %v = call {i32,i32} asm sideeffect "rdmsr", "={ax},={dx},{cx},~{memory}"(i32 \(n))
    %l = extractvalue {i32,i32} %v, 0
    %h = extractvalue {i32,i32} %v, 1
    %lo = zext i32 %l to i64
    %hi = zext i32 %h to i64
    %top = shl i64 %hi, 32
    %ret = or i64 %top, %lo
    ret i64 %ret
  }
  """)
}
