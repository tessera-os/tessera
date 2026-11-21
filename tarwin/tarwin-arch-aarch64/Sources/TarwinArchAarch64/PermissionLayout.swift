/// The encoding is fixed for the lifetime of both roots. W1 indirection
/// uses 64-bit descriptors, TCR2_EL2.PIE only and no hardware dirty updates.
public enum ArmPermissionLayout: Sendable {
  case direct, guarded

  // PIIndex uses {UXN, PXN, DBM, AP[1]}. All unspecified entries deny.
  // EL2: 8 = kernel RX; 10 = kernel RO; 12 = kernel RW. EL0: 5 = RX; 13 = RW;
  // 14 = GCS (ordinary read, no ordinary write); 15 = RO.
  public static let pir: UInt64 = 0x000c_080a_0000_0000
  public static let pire0: UInt64 = 0x89c0_0000_00a0_0000

  func userLeaf(_ pa: UInt64, write: Bool, execute: Bool) -> UInt64 {
    let leaf = armUserPage(pa, write: write, execute: execute, lpa2: false)
    guard leaf != 0 else { return 0 }
    return self == .guarded && !write && !execute ? leaf | (1 << 51) : leaf
  }

  func controlLeaf(_ pa: UInt64) -> UInt64 {
    guard self == .guarded, pa > 0, pa < 1 << 48, pa & 16383 == 0 else { return 0 }
    return pa | 0xf03 | (1 << 51) | (1 << 53) | (1 << 54)
  }
}
