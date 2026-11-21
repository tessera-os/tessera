public enum EventStatus {
  case ok, invalidHandle, wrongType, denied, invalidMask, peerClosed, limit, badState
}

public struct EventNames {
  public let status: EventStatus
  public let first, second: UInt64
  fileprivate init(_ status: EventStatus, _ first: UInt64 = 0, _ second: UInt64 = 0) {
    self.status = status
    self.first = first
    self.second = second
  }
}

/// One registry record per standalone event or linked pair. Serialize publication,
/// signalling and endpoint destruction under its lock. Keep both headers mapped
/// until the pair is retired and read epochs drain, without a cross-reference
/// between the two objects that would keep either end alive.
public struct EventEndpoints: ~Copyable {
  public static var writableSignals: UInt32 { 0xff00_0008 }
  public static var initialRights: UInt64 { 0x7cf }
  private let first: UnsafePointer<ObjectHeader>, second: UnsafePointer<ObjectHeader>?
  private var published = false, firstClosed = false, secondClosed = false
  public var paired: Bool { second != nil }

  public init?(first: UnsafePointer<ObjectHeader>, second: UnsafePointer<ObjectHeader>? = nil) {
    let type = second == nil ? TarwinKind.event : TarwinKind.eventPair
    guard first.pointee.kind == type, first.pointee.maximumRights == Self.initialRights else {
      return nil
    }
    if let second {
      guard second != first, second.pointee.kind == type,
        second.pointee.ownerJob == first.pointee.ownerJob,
        second.pointee.maximumRights == Self.initialRights
      else { return nil }
    }
    self.first = first
    self.second = second
  }

  /// Both creator references are still owned by the allocating registry.
  /// On success it releases them after publishing the record; on failure
  /// it recycles the unpublished storage. Hold the caller's table lock.
  public mutating func publish(initial: UInt32, in table: inout HandleTable) -> EventNames {
    guard !published else { return EventNames(.badState) }
    guard initial & ~Self.writableSignals == 0, second == nil || initial == 0 else {
      return EventNames(.invalidMask)
    }
    guard table.freeCount >= (paired ? 2 : 1) else { return EventNames(.limit) }
    guard first.pointee.retainIfLive() else { return EventNames(.badState) }
    if let second, !second.pointee.retainIfLive() {
      _ = first.pointee.release()
      return EventNames(.badState)
    }
    _ = first.pointee.updateSignals(clear: .max, set: initial)
    func install(_ h: UnsafePointer<ObjectHeader>, in table: inout HandleTable) -> UInt64 {
      switch table.installMoved(ObjectGrant(header: h, rights: Self.initialRights)) {
      case .installed(let name): return name
      case .limit: preconditionFailure("event publication lost reserved table capacity")
      }
    }
    let a = install(first, in: &table)
    let b: UInt64
    if let second {
      _ = second.pointee.updateSignals(clear: .max, set: 0)
      b = install(second, in: &table)
    } else {
      b = 0
    }
    published = true
    return EventNames(.ok, a, b)
  }

  /// Resolve the actual header even when a candidate registry entry was
  /// cached. The locked caller table owns the reference through notify.
  public func signal(
    name: UInt64, set: UInt32, clear: UInt32, in table: borrowing HandleTable,
    notify: (UnsafePointer<ObjectHeader>) -> Void
  ) -> EventStatus {
    switch table.reader.pinWithinEpoch(name, kind: 0, need: 0) {
    case .accessDenied: return .denied
    case .invalidHandle: return .invalidHandle
    case .wrongType: return .wrongType
    case .found(let grant):
      let h = grant.header
      let rights = grant.rights
      grant.drop { _ in preconditionFailure("lost locked event reference") }
      guard h.pointee.kind == TarwinKind.event || h.pointee.kind == TarwinKind.eventPair else {
        return .wrongType
      }
      guard published, h == first || h == second else { return .invalidHandle }
      guard rights & (1 << 6) != 0 else { return .denied }
      guard (set | clear) & ~Self.writableSignals == 0 else { return .invalidMask }
      guard h == first ? !firstClosed : !secondClosed else { return .invalidHandle }
      let target = h == first ? second ?? first : first
      guard !(target == first ? firstClosed : secondClosed), !target.pointee.released else {
        return .peerClosed
      }
      let old = target.pointee.signals
      if target.pointee.updateSignals(clear: clear, set: set) != old { notify(target) }
      return .ok
    }
  }

  /// Final endpoint destruction, not the removal of one name or a move
  /// into a message. Notify once and preserve the survivor's last signals.
  public mutating func destroy(
    _ h: UnsafePointer<ObjectHeader>, notify: (UnsafePointer<ObjectHeader>) -> Void
  ) {
    guard published, h == first || h == second, h.pointee.released else { return }
    let survivor: UnsafePointer<ObjectHeader>?
    if h == first && !firstClosed {
      firstClosed = true
      survivor = secondClosed ? nil : second
    } else if h == second && !secondClosed {
      secondClosed = true
      survivor = firstClosed ? nil : first
    } else {
      return
    }
    if let survivor, !survivor.pointee.released {
      _ = survivor.pointee.updateSignals(clear: 0, set: 1 << 2)
      notify(survivor)
    }
  }
}
