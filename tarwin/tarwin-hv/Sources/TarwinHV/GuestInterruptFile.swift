// AIA guest interrupt-file state. Identity zero is reserved. The configured
// count is 63 modulo 64; TOPI prioritizes the lowest eligible identity.
public struct GuestInterruptFile {
  private var pending: InlineArray<32, UInt64> = .init(repeating: 0)
  private var enabled: InlineArray<32, UInt64> = .init(repeating: 0)
  public let lastID: UInt16
  public var delivery = false
  public var threshold: UInt16 = 0

  public init?(lastID: UInt16) {
    guard (63...2047).contains(lastID), lastID % 64 == 63 else { return nil }
    self.lastID = lastID
  }

  public mutating func post(_ id: UInt16) -> Bool {
    guard id != 0, id <= lastID else { return false }
    pending[Int(id / 64)] |= 1 << (id % 64)
    return true
  }

  public mutating func setEnabled(_ id: UInt16, _ value: Bool) -> Bool {
    guard id != 0, id <= lastID else { return false }
    let bank = Int(id / 64)
    let mask = UInt64(1) << (id % 64)
    if value { enabled[bank] |= mask } else { enabled[bank] &= ~mask }
    return true
  }

  public func top() -> UInt16 {
    for bank in 0...Int(lastID / 64) {
      let bits = pending[bank] & enabled[bank]
      guard bits != 0 else { continue }
      let id = UInt16(bank * 64 + bits.trailingZeroBitCount)
      return threshold == 0 || id < threshold ? id : 0
    }
    return 0
  }

  public var lineAsserted: Bool { delivery && top() != 0 }

  public mutating func claim() -> UInt16 {
    let id = top()
    if id != 0 { pending[Int(id / 64)] &= ~(UInt64(1) << (id % 64)) }
    return id
  }
}
