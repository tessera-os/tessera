public enum DmaAccess: Equatable {
  case deviceRead
  case deviceWrite
  case both
  var memoryRights: UInt64 {
    switch self {
    case .deviceRead: 4
    case .deviceWrite: 8
    case .both: 12
    }
  }
}
public struct DmaSpan: Equatable {
  public let offset: UInt64
  public let bytes: UInt64
  public let access: DmaAccess

  public init(offset: UInt64, bytes: UInt64, access: DmaAccess) {
    self.offset = offset
    self.bytes = bytes
    self.access = access
  }
}
public struct DmaMapping: Equatable {
  public let id: UInt64
  public let address: UInt64

  public init(id: UInt64, address: UInt64) {
    self.id = id
    self.address = address
  }
}
public enum MapDma: Equatable {
  case refused
  case retry
  case mapped(DmaMapping)
  case quarantined(UInt64)
}
public struct DomainEntry {
  let id: UInt64
  var buffer: UInt64 = 0
  var retirement: DmaRetirement

  public static var vacant: Self {
    Self(id: 0, retirement: DmaRetirement(domain: 0, pin: 0, base: 0, bytes: 0, phase: .released))
  }
}

// Serialized with slot revocation. VM's pin resolves COW, exact writable
// range, ownership and charge; mapPinned installs only the requested access.
// A zero pin is failure; no identity address, pin, or partially installed
// translation is ever returned to a driver.
public struct SlotDomain: ~Copyable {
  public let group: UInt64
  public let koid: UInt64
  public let epoch: UInt64
  public let aperture: DeviceRange
  public let page: UInt64
  public internal(set) var serial: UInt64 = 0
  public internal(set) var count: Int = 0
  private let entries: UnsafeMutableBufferPointer<DomainEntry>

  var hasCapacity: Bool { count < entries.count && serial < .max }

  /// Under the domain lock, before installing the new buffer handle.
  mutating func bindLastMapping(_ id: UInt64, buffer: UInt64) {
    precondition(
      count > 0 && entries[count - 1].id == id && entries[count - 1].buffer == 0 && buffer != 0)
    entries[count - 1].buffer = buffer
  }

  func mapping(forBuffer buffer: UInt64) -> UInt64? {
    guard buffer != 0 else { return nil }
    for i in 0..<count where entries[i].buffer == buffer { return entries[i].id }
    return nil
  }

  public mutating func create(
    _ domain: borrowing PinnedIoHandle, _ memory: borrowing PinnedIoHandle, _ slot: DeviceSlotState,
    _ process: UInt64,
    _ memorySize: UInt64, _ span: DmaSpan, _ randomWord: UInt64, _ pin: (UInt64, DmaSpan) -> UInt64,
    _ mapPinned: (UInt64, UInt64, UInt64, DmaSpan) -> Bool
  ) -> MapDma {
    if !domain.permits(.dmaBufferCreate, koid) || slot.group != group || !slot.owns(process, epoch)
      || !hasCapacity
      || !deviceAligned(span.offset, page)
      || span.bytes == 0 || !deviceAligned(span.bytes, page) || span.offset >= memorySize
      || span.bytes > memorySize - span.offset
    {
      return .refused
    }
    let required = span.access.memoryRights
    if memory.koid == 0 || memory.kind != .memory || memory.rights & required != required {
      return .refused
    }
    let candidate = chooseDmaAddress(aperture, span.bytes, page, randomWord, count) { i in
      DeviceRange(base: entries[i].retirement.base, length: entries[i].retirement.bytes)
    }
    switch candidate {
    case .unavailable: return .retry
    case .selected(let iova):
      let pinned = pin(memory.koid, span)
      if pinned == 0 { return .refused }
      serial += 1
      let entry = DomainEntry(
        id: serial,
        retirement: DmaRetirement(
          domain: koid, pin: pinned, base: iova, bytes: span.bytes, phase: .mapped))
      entries[count] = entry
      count += 1
      if !mapPinned(koid, iova, pinned, span) { return .quarantined(serial) }
      return .mapped(DmaMapping(id: serial, address: iova))
    }
  }

  // Internal mapping IDs only, after DmaBuffer-close authority has been
  // resolved. A failed retirement stays in the address allocator's set.
  public mutating func retire(
    _ id: UInt64, _ detach: (UInt64, UInt64, UInt64) -> Bool,
    _ invalidate: (UInt64, UInt64, UInt64) -> Bool, _ drainAtcs: (UInt64, UInt64, UInt64) -> Bool,
    _ unpin: (UInt64) -> Void
  ) -> Bool {
    for i in 0..<count {
      if entries[i].id == id {
        if !entries[i].retirement.retire(detach, invalidate, drainAtcs, unpin) { return false }
        count -= 1
        entries[i] = entries[count]
        entries[count] = .vacant
        return true
      }
    }
    return false
  }

  /// The registry supplies exclusively owned, initialized slab storage that
  /// outlives this domain. Drain all mappings before releasing that slab.
  public init(
    group: UInt64, koid: UInt64, epoch: UInt64, aperture: DeviceRange, page: UInt64,
    storage: UnsafeMutableBufferPointer<DomainEntry>
  ) {
    self.group = group
    self.koid = koid
    self.epoch = epoch
    self.aperture = aperture
    self.page = page
    self.entries = storage
  }
}
