// Offset and scale expressed as an anchor and a rational multiplier. The
// destination reanchors the counter before resuming a migrated vCPU.
public struct GuestClock {
  public let hostAnchor: UInt64
  public let guestAnchor: UInt64
  public let numerator: UInt64
  public let denominator: UInt64

  public init?(host: UInt64, guest: UInt64, numerator: UInt64, denominator: UInt64) {
    guard numerator != 0 && denominator != 0 else { return nil }
    hostAnchor = host
    guestAnchor = guest
    self.numerator = numerator
    self.denominator = denominator
  }

  public func ticks(at host: UInt64) -> UInt64? {
    guard host >= hostAnchor else { return nil }
    let product = (host - hostAnchor).multipliedFullWidth(by: numerator)
    guard product.high < denominator else { return nil }
    let scaled = denominator.dividingFullWidth(product).quotient
    let (ticks, overflow) = guestAnchor.addingReportingOverflow(scaled)
    return overflow ? nil : ticks
  }

  // Round up when converting a guest comparator into a host deadline.
  public func hostDeadline(for guest: UInt64) -> UInt64? {
    guard guest > guestAnchor else { return hostAnchor }
    let product = (guest - guestAnchor).multipliedFullWidth(by: denominator)
    guard product.high < numerator else { return nil }
    let (whole, remainder) = numerator.dividingFullWidth(product)
    let (floor, overflow) = hostAnchor.addingReportingOverflow(whole)
    guard !overflow, remainder == 0 || floor != .max else { return nil }
    return floor + (remainder == 0 ? 0 : 1)
  }
}

public struct GuestComparator {
  public var compare: UInt64
  public var enabled: Bool
  public var masked: Bool
  public private(set) var asserted = false

  public init(compare: UInt64 = .max, enabled: Bool = false, masked: Bool = true) {
    self.compare = compare
    self.enabled = enabled
    self.masked = masked
  }

  // Level-triggered line: clearing the guest enable/mask state or moving the
  // compare value ahead retracts an assertion. Failed delivery is retriable.
  public mutating func update(at guestTicks: UInt64, setLine: (Bool) -> Bool) -> Bool {
    let level = enabled && !masked && guestTicks >= compare
    guard level != asserted else { return true }
    guard setLine(level) else { return false }
    asserted = level
    return true
  }
}
