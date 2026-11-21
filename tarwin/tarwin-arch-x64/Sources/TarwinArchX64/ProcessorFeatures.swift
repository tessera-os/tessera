// Actual CPUID results, four zero-extended registers per row, in the stage-0
// snapshot order: 0, 80000000, 1, 7:0, 80000001, 80000007, D:0.
// These are CPU capabilities, not enabled OS state or a launch decision.
public struct X64TargetFeatures {
  public let namedBaseline: Bool
  public let shadowStack: Bool
  public let indirectBranchTracking: Bool
  public let vectorCarrylessMultiply: Bool
  public let invariantCounter: Bool
  public let deadlineTimer: Bool

  public init?(_ v: UnsafeBufferPointer<UInt64>) {
    guard v.count >= 28, v[0] >= 13, v[4] >= 0x80000007 else { return nil }
    func has(_ i: Int, _ mask: UInt64) -> Bool { v[i] & mask == mask }
    shadowStack = has(14, 1 << 7)
    indirectBranchTracking = has(15, 1 << 20)
    vectorCarrylessMultiply = has(14, 1 << 10)
    invariantCounter = has(23, 1 << 8)
    deadlineTimer = has(10, 1 << 24)
    // CPUID.1:ECX (SSE3,PCLMUL,SSSE3,FMA,CX16,SSE4.1/2,MOVBE,POPCNT,
    // AES,XSAVE,AVX,F16C,RDRAND). 7:EBX (BMI1/2,AVX2,ERMS,RDSEED).
    namedBaseline = has(10, 0x76d8_3203) && has(13, 0x0004_0328)
      && has(14, 1 << 9) && vectorCarrylessMultiply && shadowStack && indirectBranchTracking
      && has(18, 0x21) // LAHF/SAHF and LZCNT
      && has(24, 7) // XSAVE x87/SSE/YMM state components
  }
}
