// Isolated EL2 diagnostic. Only PSCI_VERSION and AFFINITY_INFO64, with level
// zero; no call number or entry address comes from boot media or userspace.
print("""
define i64 @tarboot_psci_version() naked nounwind {
  call void asm sideeffect "mov w0, #0x84000000\\0Asmc #0\\0Aret", "~{memory}"()
  unreachable
}
define i64 @tarboot_psci_affinity(i64 %id) naked nounwind {
  call void asm sideeffect "mov x1, x0\\0Amov w0, #4\\0Amovk w0, #0xc400, lsl #16\\0Amov x2, xzr\\0Asmc #0\\0Aret", "~{memory}"()
  unreachable
}
define i64 @tarboot_affinity_id() nounwind {
  %id = call i64 asm sideeffect "mrs $0, mpidr_el1", "=r"()
  ret i64 %id
}
""")
