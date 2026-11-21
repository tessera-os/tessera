// Fixed MSR indices, private kernel text. LLVM handles the C argument
// register for both the ELF and diagnostic EFI PE calling conventions.
print("""
define i64 @tarwin_local_irq_masked() {
  %f = call i64 asm sideeffect "pushfq; popq $0", "=r,~{memory}"()
  %i = and i64 %f, 512
  %m = icmp eq i64 %i, 0
  %z = zext i1 %m to i64
  ret i64 %z
}
""")
for (name,index) in [("apic_base", 0x1b), ("svr", 0x80f), ("lvt", 0x832)] {
  print("""
  define i64 @tarwin_local_\(name)() {
    %r = call {i32,i32} asm sideeffect "rdmsr", "={ax},={dx},{cx},~{memory}"(i32 \(index))
    %a = extractvalue {i32,i32} %r, 0
    %d = extractvalue {i32,i32} %r, 1
    %l = zext i32 %a to i64
    %h = zext i32 %d to i64
    %s = shl i64 %h, 32
    %v = or i64 %s, %l
    ret i64 %v
  }
  """)
}
print("""
define void @tarwin_local_tsc_compare(i64 %v) {
  %lo = trunc i64 %v to i32
  %s = lshr i64 %v, 32
  %hi = trunc i64 %s to i32
  call void asm sideeffect "mfence; wrmsr", "{ax},{dx},{cx},~{memory}"(i32 %lo,i32 %hi,i32 1760)
  ret void
}
""")
