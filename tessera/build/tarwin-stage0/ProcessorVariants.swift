// Stage 0 only: Apple Swift has no source-level TIR [privileged] asm.
// Keep trusted inline instruction templates inside the three base variants;
// the host emits LLVM inline asm for the integrated assembler, not a separate
// C or assembler implementation. No assembly text comes from boot media.
import Foundation

enum BaseISA: String { case aarch64, x86_64, riscv64 }

// ABI: firmware calls with 32 private aligned UInt64s and zeroes them first.
// No interrupt enable, exception level change, register write or mapping.
func privilegedSnapshot(_ base: BaseISA) -> String {
  var ir = "define void @tarwin_processor_snapshot(ptr nocapture %out) nounwind {\n"
  func store(_ i: Int, _ value: String) {
    ir +=
      "%dst\(i) = getelementptr i64, ptr %out, i32 \(i)\nstore i64 \(value), ptr %dst\(i), align 8\n"
  }
  switch base {
  case .aarch64:
    // EL1 or EL2 firmware, feature registers only. ISAR2 is named by encoding
    // so the assembler itself needs no post-baseline architecture switch.
    let registers = [
      "CurrentEL", "ID_AA64PFR0_EL1", "ID_AA64PFR1_EL1", "ID_AA64ISAR0_EL1",
      "ID_AA64ISAR1_EL1", "S3_0_C0_C6_2", "ID_AA64MMFR0_EL1", "ID_AA64MMFR1_EL1",
      "ID_AA64MMFR2_EL1", "CNTFRQ_EL0", "MIDR_EL1", "MPIDR_EL1",
    ]
    for (i, reg) in registers.enumerated() {
      ir += "%v\(i) = call i64 asm sideeffect \"mrs $0, \(reg)\", \"=r,~{memory}\"()\n"
      store(i, "%v\(i)")
    }
  case .x86_64:
    // CPUID's maximum leaves are captured first. Consumers must check them
    // before interpreting later results, even when a VMM aliases unknown leaves.
    let leaves: [UInt32] = [0, 0x8000_0000, 1, 7, 0x8000_0001, 0x8000_0007, 0xd]
    for (i, leaf) in leaves.enumerated() {
      let regs = "{i32,i32,i32,i32}"
      ir +=
        "%row\(i) = call \(regs) asm sideeffect \"cpuid\", \"={ax},={bx},={cx},={dx},0,2,~{memory}\"(i32 \(leaf),i32 0)\n"
      for j in 0..<4 {
        let n = 4 * i + j
        ir += "%w\(n) = extractvalue \(regs) %row\(i), \(j)\n%v\(n) = zext i32 %w\(n) to i64\n"
        store(n, "%v\(n)")
      }
    }
  case .riscv64:
    // SBI BASE: version, machine IDs, and TIME/IPI/RFENCE/HSM availability.
    // Preserve each sbiret.error beside its value; it is not an ISA feature.
    let probes: [(Int, Int)] = [
      (0, 0), (4, 0), (5, 0), (6, 0), (3, 0x5449_4d45), (3, 0x735049),
      (3, 0x5246_4e43), (3, 0x48534d),
    ]
    for (i, probe) in probes.enumerated() {
      ir +=
        "%row\(i) = call {i64,i64} asm sideeffect \"ecall\", \"={a0},={a1},0,{a6},{a7},~{memory}\"(i64 \(probe.1),i64 \(probe.0),i64 16)\n"
      for j in 0..<2 {
        let n = 2 * i + j
        ir += "%v\(n) = extractvalue {i64,i64} %row\(i), \(j)\n"
        store(n, "%v\(n)")
      }
    }
  }
  return ir + "ret void\n}\n"
}
guard CommandLine.arguments.count == 2, let isa = BaseISA(rawValue: CommandLine.arguments[1]) else {
  exit(2)
}
print(privilegedSnapshot(isa))
// AArch64 PE compiler stack-check ABI (16-byte units in x15, preserved).
// Firmware owns the active stack; touch each intervening page before SP is
// adjusted. Do not replace with a stub even in the isolated verifier build.
if isa == .aarch64 {
  print(
    """
    define void @__chkstk() naked nounwind {
      call void asm sideeffect "mov x16, sp@NL@lsl x17, x15, #4@NL@1: cmp x17, #4096@NL@b.ls 2f@NL@sub x16, x16, #4096@NL@ldr xzr, [x16]@NL@sub x17, x17, #4096@NL@b 1b@NL@2: sub x16, x16, x17@NL@ldr xzr, [x16]@NL@ret", "~{memory}"()
      unreachable
    }
    """.replacingOccurrences(of: "@NL@", with: "\\0A"))
}
