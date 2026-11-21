import TarwinTrapDecode
import Testing

@Test func distinguishesSyscallsFromOtherSVCImmediatesAndBreakpoints() {
  #expect(AArch64TrapInstruction.decode(0xd400_0001) == .svc(immediate: 0))
  #expect(AArch64TrapInstruction.decode(0xd400_1001) == .svc(immediate: 0x80))
  #expect(AArch64TrapInstruction.decode(0xd41f_ffe1) == .svc(immediate: .max))
  #expect(AArch64TrapInstruction.decode(0xd42f_eac0) == .other)
  #expect(AArch64TrapInstruction.decode(0xd400_0002) == .other)
  #expect(AArch64TrapInstruction.isSyscallInstruction(0xd400_0001))
  #expect(!AArch64TrapInstruction.isSyscallInstruction(0xd400_1001))
  #expect(!AArch64TrapInstruction.isSyscallInstruction(0xd42f_eac0))
}

@Test func recognizesOnlyTheGuestThreadPointerRead() {
  #expect(AArch64TrapInstruction.decode(0xd53b_d040) == .readThreadPointer(destination: 0))
  #expect(AArch64TrapInstruction.decode(0xd53b_d05f) == .readThreadPointer(destination: 31))
  #expect(AArch64TrapInstruction.decode(0xd51b_d040) == .other) // msr tpidr_el0, x0
  #expect(AArch64TrapInstruction.decode(0xd53b_d060) == .other) // mrs x0, tpidrro_el0
}
