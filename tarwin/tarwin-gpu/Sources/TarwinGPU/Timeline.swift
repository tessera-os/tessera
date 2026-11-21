public enum WaitResult: Equatable {
  case denied
  case ready
  case queued
  case full
  case duplicate
}
public struct FenceWait: Equatable {
  public let key: UInt64
  public let target: UInt64
  public let priority: UInt32

  public init(key: UInt64, target: UInt64, priority: UInt32) {
    self.key = key
    self.target = target
    self.priority = priority
  }
}

// Serialized by the fence lock. Callbacks publish/enqueue only; they must
// not block or re-enter the same fence. Rights come from a resolved handle.
public struct GpuTimeline: ~Copyable {
  public internal(set) var value: UInt64 = 0
  public internal(set) var count: Int = 0
  private let waiters: UnsafeMutableBufferPointer<FenceWait>

  public func inheritedPriority() -> UInt32 {
    var best: UInt32 = 0
    for i in 0..<count {
      if waiters[i].priority > best { best = waiters[i].priority }
    }
    return best
  }

  public mutating func waitFor(_ canWait: Bool, _ w: FenceWait, _ inherit: (UInt32) -> Void)
    -> WaitResult
  {
    if !canWait { return .denied }
    if w.target <= value { return .ready }
    for i in 0..<count { if waiters[i].key == w.key { return .duplicate } }
    if count >= waiters.count { return .full }
    waiters[count] = w
    count += 1
    inherit(inheritedPriority())
    return .queued
  }

  public mutating func cancel(_ key: UInt64, _ inherit: (UInt32) -> Void) -> Bool {
    for i in 0..<count {
      if waiters[i].key == key {
        count -= 1
        waiters[i] = waiters[count]
        inherit(inheritedPriority())
        return true
      }
    }
    return false
  }

  public mutating func advance(
    _ canSignal: Bool, _ target: UInt64, _ publishRelease: (UInt64) -> Void,
    _ wake: (UInt64) -> Void, _ inherit: (UInt32) -> Void
  ) -> Bool {
    if !canSignal || target < value { return false }
    if target == value { return true }
    publishRelease(target)
    value = target
    var live: Int = 0
    for i in 0..<count {
      let w = waiters[i]
      if w.target <= target {
        wake(w.key)
      } else {
        waiters[live] = w
        live += 1
      }
    }
    count = live
    inherit(inheritedPriority())
    return true
  }

  /// Exclusive, initialized storage must outlive the fence, including the
  /// final interrupt and wake. Signalling never allocates or copies a buffer.
  public init(storage: UnsafeMutableBufferPointer<FenceWait>) {
    self.waiters = storage
  }
}
