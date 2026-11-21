// Protected by the port lock. Reserve storage before accepting an operation
// so a completion (including cancellation) never needs to allocate. The
// shared completion ring has its own space; do not recycle the credit until
// the record is published there or dequeued directly.
public struct PortCredits {
  public let capacity: UInt32
  public internal(set) var pending: UInt32
  public internal(set) var available: UInt32

  public func free() -> UInt32 {
    if capacity > 65536 || pending > capacity || available >= capacity - pending { return 0 }
    return capacity - pending - available
  }

  public mutating func reserve() -> Bool {
    if free() == 0 { return false }
    pending += 1
    return true
  }

  public mutating func postUser() -> Bool {
    if free() == 0 { return false }
    available += 1
    return true
  }

  // Caller owns exactly one pending operation; cancelling it uses the same
  // completion path as success and changes only the packet's error.
  public mutating func complete() -> Bool {
    if pending == 0 { return false }
    pending -= 1
    available += 1
    return true
  }

  public mutating func take() -> Bool {
    if available == 0 { return false }
    available -= 1
    return true
  }

  public init(capacity: UInt32, pending: UInt32, available: UInt32) {
    self.capacity = capacity
    self.pending = pending
    self.available = available
  }
}
