// Freestanding Swift has no port-I/O intrinsic on x86.
print("""
define i64 @q35_gen_word(i64 %addr) {
  %p = inttoptr i64 %addr to ptr
  %v = load volatile i64, ptr %p, align 8
  ret i64 %v
}
define void @q35_gen_note(i8 %byte) {
  call void asm sideeffect "outb $0, $$0xe9", "{al},~{memory}"(i8 %byte)
  ret void
}
""")
