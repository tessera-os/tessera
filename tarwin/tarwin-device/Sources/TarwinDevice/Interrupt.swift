// Serialized by the interrupt object's lock. A full port leaves the IRQ
// masked with a pending notification, not lost or spuriously re-enabled.
public enum IrqState: Equatable {
  case armed
  case pending
  case delivered
  case revoked
}
public struct DriverInterrupt: Equatable {
  public let slotEpoch: UInt64
  public internal(set) var state: IrqState

  public mutating func deliver(_ acknowledgeAndMask: () -> Void, _ post: () -> Bool) -> Bool {
    if state == .armed {
      acknowledgeAndMask()
      state = .pending
    }
    return retryPost(post)
  }

  public mutating func retryPost(_ post: () -> Bool) -> Bool {
    if state != .pending || !post() { return false }
    state = .delivered
    return true
  }

  public mutating func complete(_ ownerEpoch: UInt64, _ unmask: () -> Void) -> Bool {
    if slotEpoch != ownerEpoch || state != .delivered { return false }
    state = .armed
    unmask()
    return true
  }

  public mutating func revoke(_ mask: () -> Void) {
    if state != .revoked { mask() }
    state = .revoked
  }

  public init(slotEpoch: UInt64, state: IrqState) {
    self.slotEpoch = slotEpoch
    self.state = state
  }
}
