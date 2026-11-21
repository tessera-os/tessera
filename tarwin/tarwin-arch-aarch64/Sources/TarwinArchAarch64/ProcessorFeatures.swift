// Arm ARM ID_AA64{PFR,ISAR,MMFR} register fields, TVISA §30.2. Accept only
// recognized encodings. A single boot CPU's result says nothing about other
// cores, PSCI, firmware trust, GIC topology or applied security controls.
public struct ArmProcessorFeatures {
  public let baseline: Bool
  public let w0Registers: Bool

  public init?(_ raw: UnsafeBufferPointer<UInt64>) {
    guard raw.count >= 12 else { return nil }
    func field(_ index: Int, _ shift: Int) -> UInt64 { raw[index] >> shift & 15 }
    let pac =
      (1...6).contains(field(4, 4)) || (1...6).contains(field(4, 8))
      || (1...6).contains(field(5, 12))
    baseline =
      field(1, 16) == 1 && field(1, 20) == 1  // FP16 scalar and vector
      && field(3, 16) == 1 && (2...3).contains(field(3, 20))  // CRC32, LSE
      && field(8, 32) == 1 && field(3, 28) == 1 && field(3, 44) == 1  // LSE2, RDM, DP
      && (2...3).contains(field(4, 20)) && field(4, 12) == 1 && field(4, 16) == 1  // RCpc2, JSCVT, FCMA
      && field(4, 32) == 1 && field(3, 52) == 2 && field(4, 36) == 1  // FRINTTS, FLAGM2, SB
      && (1...2).contains(field(2, 4)) && field(2, 0) == 1 && pac
    w0Registers =
      baseline && raw[0] == 8 && (1...2).contains(field(1, 8))
      && field(7, 8) == 1 && (2...3).contains(field(7, 20))
      && (1...2).contains(field(6, 20)) && (field(1, 24) == 1 || field(1, 24) == 3)
      && raw[9] > 0 && raw[9] <= UInt32.max
  }
}
