import Synchronization

/// The kernel instantiates one source at boot. Exhaustion fails closed.
public struct KoidSource: ~Copyable, Sendable {
  private let last: Atomic<UInt64>
  public init() { last = Atomic(0) }
  init(after value: UInt64) { last = Atomic(value) }
  public borrowing func issue() -> UInt64? {
    var observed = last.load(ordering: .relaxed)
    while observed != .max {
      let next = observed + 1
      let update = last.compareExchange(expected: observed, desired: next, ordering: .relaxed)
      if update.exchanged { return next }
      observed = update.original
    }
    return nil
  }
}

public enum ReleaseAction { case stillLive, destroy, alreadyReleased }

/// Hold a live reference or a read epoch before touching the header. Only
/// the final releaser cancels operations and queues storage for reclamation.
public struct ObjectHeader: ~Copyable, Sendable {
  public let koid: UInt64
  public let ownerJob: UInt64
  public let kind: UInt32
  public let maximumRights: UInt64
  private let references = Atomic<UInt64>(1)
  private let signalBits = Atomic<UInt32>(0)

  public init?(source: borrowing KoidSource, ownerJob: UInt64, kind: UInt32, maximumRights: UInt64)
  {
    guard objectKindAllocated(kind), maximumRights >> 32 == 0,
      kind != TarwinKind.presence || maximumRights & 3 == 0,
      let koid = source.issue()
    else { return nil }
    self.koid = koid
    self.ownerJob = ownerJob
    self.kind = kind
    self.maximumRights = maximumRights
  }

  public borrowing func retainIfLive() -> Bool {
    var seen = references.load(ordering: .relaxed)
    while seen != 0 && seen != .max {
      let update = references.compareExchange(
        expected: seen, desired: seen + 1, ordering: .acquiring)
      if update.exchanged { return true }
      seen = update.original
    }
    return false
  }

  public borrowing func release() -> ReleaseAction {
    var seen = references.load(ordering: .relaxed)
    while seen != 0 {
      let update = references.compareExchange(
        expected: seen, desired: seen - 1, ordering: .acquiringAndReleasing)
      if update.exchanged { return seen == 1 ? .destroy : .stillLive }
      seen = update.original
    }
    return .alreadyReleased
  }

  public var signals: UInt32 { signalBits.load(ordering: .acquiring) }
  var released: Bool { references.load(ordering: .acquiring) == 0 }

  /// Call under the object's observer lock so changes and FIFO observer
  /// delivery are ordered together. Masks are validated by the operation.
  public borrowing func updateSignals(clear: UInt32, set: UInt32) -> UInt32 {
    var old = signalBits.load(ordering: .relaxed)
    while true {
      let new = (old & ~clear) | set
      let update = signalBits.compareExchange(
        expected: old, desired: new, ordering: .acquiringAndReleasing)
      if update.exchanged { return new }
      old = update.original
    }
  }
}
