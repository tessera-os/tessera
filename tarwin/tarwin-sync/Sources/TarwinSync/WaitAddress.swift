public struct WaitAddress {
  public internal(set) var frame: UInt64
  public internal(set) var offset: UInt32

  // width isn't part of the wake key: Sync.wake takes only an address.
  public func same(_ other: WaitAddress) -> Bool {
    return frame == other.frame && offset == other.offset
  }

  // Validate after translating and pinning the shared physical page.
  public func valid(_ pageBytes: UInt32, _ width: UInt32) -> Bool {
    if pageBytes != 4096 && pageBytes != 16384 { return false }
    if width != 4 && width != 8 { return false }
    return offset <= pageBytes - width && (offset & (width - 1)) == 0
  }

  public func bucketHash() -> UInt64 {
    return frame ^ (frame >> 29) ^ (UInt64(offset) << 11) ^ (frame << 17)
  }

  public init(frame: UInt64, offset: UInt32) {
    self.frame = frame
    self.offset = offset
  }
}

// One intrusive wait record. The hash bucket lock serializes register,
// requeue, wake, timeout and cancellation, including the final word load.
// The scheduler owns the block/wake transition and inherited context.
public struct AddressWait {
  public internal(set) var key: WaitAddress
  public internal(set) var queued: Bool
  public internal(set) var owner: UInt64

  public mutating func arm(
    _ target: WaitAddress, _ pageBytes: UInt32, _ width: UInt32,
    _ observed: UInt64, _ expected: UInt64, _ ownerId: UInt64
  ) -> Bool {
    if queued || !target.valid(pageBytes, width) || observed != expected { return false }
    if width == 4 && (observed >> 32) != 0 { return false }
    key.frame = target.frame
    key.offset = target.offset
    owner = ownerId
    queued = true
    return true
  }

  public mutating func remove(_ from: WaitAddress) -> Bool {
    if !queued || !key.same(from) { return false }
    queued = false
    owner = 0
    return true
  }

  // Caller holds both bucket locks in increasing index order.
  public mutating func requeue(
    _ from: WaitAddress, _ to: WaitAddress,
    _ pageBytes: UInt32, _ width: UInt32, _ newOwner: UInt64
  ) -> Bool {
    if !queued || !key.same(from) || !to.valid(pageBytes, width) { return false }
    key.frame = to.frame
    key.offset = to.offset
    owner = newOwner
    return true
  }

  public init(key: WaitAddress, queued: Bool, owner: UInt64) {
    self.key = key
    self.queued = queued
    self.owner = owner
  }
}
