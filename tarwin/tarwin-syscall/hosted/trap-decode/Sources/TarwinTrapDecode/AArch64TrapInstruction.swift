public enum AArch64TrapInstruction: Sendable, Equatable {
  case svc(immediate: UInt16)
  case readThreadPointer(destination: UInt32)
  case other

  public static func decode(_ word: UInt32) -> Self {
    if word & 0xffe0_001f == 0xd400_0001 {
      return .svc(immediate: UInt16(truncatingIfNeeded: word >> 5))
    }
    if word & 0xffff_ffe0 == 0xd53b_d040 {
      return .readThreadPointer(destination: word & 31)
    }
    return .other
  }

  public static func isSyscallInstruction(_ word: UInt32) -> Bool {
    decode(word) == .svc(immediate: 0)
  }
}
