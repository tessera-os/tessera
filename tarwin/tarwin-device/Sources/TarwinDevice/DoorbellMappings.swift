import TarwinObject

public struct DoorbellPage {
  public let offset: UInt64
  fileprivate var client: UnsafePointer<ObjectHeader>?
  public init(offset: UInt64) { self.offset = offset }
}

public struct DoorbellMapping: Equatable {
  public let range: UInt64, epoch: UInt64, process: UInt64, offset: UInt64, physical: UInt64,
    bytes: UInt64
}

/// On partial failure the VM keeps the client from accessing the page and
/// schedules slot teardown before reporting needsRevocation.
public enum DoorbellInstall { case installed, unchanged, needsRevocation }
public enum DoorbellReply: Equatable {
  case mapped, invalidHandle, wrongType, denied, unavailable, notDesignated, busy, mappingFailed
}

/// The platform owns this range payload, an exclusive, initialized page slab
/// and its header for the whole slot lifetime. Hold the slot and address-space
/// locks and the caller's handle read epoch. Callbacks must not reenter.
public struct DoorbellMappings: ~Copyable {
  private let range: UnsafePointer<ObjectHeader>, epoch: UInt64, bytes: UInt64, group: UInt64
  private let pages: UnsafeMutableBufferPointer<DoorbellPage>
  private let base: UInt64
  private var closed = false
  public init?(
    range: UnsafePointer<ObjectHeader>, slot: DeviceSlotState, aperture: DeviceRange,
    pageBytes: UInt64, pages: UnsafeMutableBufferPointer<DoorbellPage>
  ) {
    guard range.pointee.kind == TarwinKind.mmioRange, slot.phase == .active, aperture.valid(),
      deviceAligned(aperture.base, pageBytes), pageBytes <= aperture.length, !pages.isEmpty
    else { return nil }
    for i in pages.indices {
      let page = pages[i]
      guard page.client == nil, page.offset % pageBytes == 0,
        page.offset <= aperture.length - pageBytes,
        i == 0 || pages[i - 1].offset < page.offset
      else { return nil }
    }
    self.range = range
    base = aperture.base
    group = slot.group
    epoch = slot.epoch
    bytes = pageBytes
    self.pages = pages
  }

  private func mapping(_ i: Int, _ client: UnsafePointer<ObjectHeader>) -> DoorbellMapping {
    DoorbellMapping(
      range: range.pointee.koid, epoch: epoch, process: client.pointee.koid,
      offset: pages[i].offset, physical: base + pages[i].offset, bytes: bytes)
  }

  /// Resolve the current group record under the slot lock.
  /// The VM must pin the address space, reject exiting processes,
  /// and either enforce write-only, uncached, NX or refuse without a mapping.
  public mutating func grant(
    rangeName: UInt64, processName: UInt64, offset: UInt64,
    slot: DeviceSlotState, callerProcess: UInt64, caller: HandleReadView,
    installWriteOnlyUcNx: (DoorbellMapping, UnsafePointer<ObjectHeader>) -> DoorbellInstall,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> DoorbellReply {
    guard !closed, slot.group == group, slot.epoch == epoch, slot.phase == .active else {
      return .unavailable
    }
    guard slot.owns(callerProcess, epoch) else { return .denied }
    switch caller.pinWithinEpoch(rangeName, kind: TarwinKind.mmioRange, need: 528) {
    case .accessDenied: return .denied
    case .invalidHandle: return .invalidHandle
    case .wrongType: return .wrongType
    case .found(let r):
      let exact = r.header == range
      r.drop(retire: retire)
      guard exact else { return .invalidHandle }
    }
    var i = 0
    while i < pages.count && pages[i].offset < offset { i += 1 }
    guard i < pages.count, pages[i].offset == offset else { return .notDesignated }
    guard pages[i].client == nil else { return .busy }
    switch caller.pinWithinEpoch(processName, kind: TarwinKind.process, need: 512) {
    case .accessDenied: return .denied
    case .invalidHandle: return .invalidHandle
    case .wrongType: return .wrongType
    case .found(let p):
      let h = p.header
      guard h.pointee.retainIfLive() else {
        p.drop(retire: retire)
        return .unavailable
      }
      pages[i].client = h
      p.drop(retire: retire)
      switch installWriteOnlyUcNx(mapping(i, h), h) {
      case .installed: return .mapped
      case .unchanged:
        forget(i, h, retire)
      case .needsRevocation:
        closed = true
      }
      return .mappingFailed
    }
  }

  private func forget(
    _ i: Int, _ h: UnsafePointer<ObjectHeader>,
    _ retire: (UnsafePointer<ObjectHeader>) -> Void
  ) {
    pages[i].client = nil
    if h.pointee.release() == .destroy { retire(h) }
  }

  /// Invoke in the slot's CPU-unmap phase, before drain/reset/reassignment.
  /// Acknowledge only after removing the mapping and synchronizing all CPU
  /// translations. Failed mappings keep their client pins for an idempotent retry.
  public mutating func revoke(
    group: UInt64, epoch: UInt64,
    unmapAndSync: (DoorbellMapping, UnsafePointer<ObjectHeader>) -> Bool,
    retire: (UnsafePointer<ObjectHeader>) -> Void
  ) -> Bool {
    guard self.group == group, self.epoch == epoch else { return false }
    closed = true
    var drained = true
    for i in pages.indices {
      guard let client = pages[i].client else { continue }
      if unmapAndSync(mapping(i, client), client) {
        forget(i, client, retire)
      } else {
        drained = false
      }
    }
    return drained
  }
}
