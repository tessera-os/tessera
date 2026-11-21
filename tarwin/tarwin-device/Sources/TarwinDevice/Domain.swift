public enum DmaAccess: Equatable {
  case deviceRead
  case deviceWrite
  case both
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
struct DomainEntry {
  let id: UInt64
  var visible: Bool
  var retirement: DmaRetirement
}

// Serialized with slot revocation. VM's pin resolves COW, exact writable
// range, ownership and charge; mapPinned installs only the requested access.
// A zero pin is failure; no identity address, pin, or partially installed
// translation is ever returned to a driver.
public struct SlotDomain {
  public let group: UInt64
  public let koid: UInt64
  public let epoch: UInt64
  public let aperture: DeviceRange
  public let page: UInt64
  public let limit: Int
  public internal(set) var serial: UInt64 = 0
  public internal(set) var count: Int = 0
  var entries: [DomainEntry] = []

  public mutating func create(
    _ domain: PinnedIoHandle, _ memory: PinnedIoHandle, _ slot: DeviceSlotState, _ process: UInt64,
    _ memorySize: UInt64, _ span: DmaSpan, _ randomWord: UInt64, _ pin: (UInt64, DmaSpan) -> UInt64,
    _ mapPinned: (UInt64, UInt64, UInt64, DmaSpan) -> Bool
  ) -> MapDma {
    if !domain.permits(.dmaBufferCreate, koid) || slot.group != group || !slot.owns(process, epoch)
      || count >= limit || serial == 0xffff_ffff_ffff_ffff || !deviceAligned(span.offset, page)
      || span.bytes == 0 || !deviceAligned(span.bytes, page) || span.offset >= memorySize
      || span.bytes > memorySize - span.offset
    {
      return .refused
    }
    var required: UInt64 = 4
    if span.access == .deviceWrite { required = 8 }
    if span.access == .both { required = 12 }
    if memory.koid == 0 || memory.kind != .memory || memory.rights & required != required {
      return .refused
    }
    var occupied: [DeviceRange] = []
    for i in 0..<count {
      occupied.append(
        DeviceRange(base: entries[i].retirement.base, length: entries[i].retirement.bytes))
    }
    switch chooseDmaAddress(aperture, span.bytes, page, randomWord, occupied) {
    case .unavailable: return .retry
    case .selected(let iova):
      let pinned = pin(memory.koid, span)
      if pinned == 0 { return .refused }
      serial += 1
      let entry = DomainEntry(
        id: serial, visible: false,
        retirement: DmaRetirement(
          domain: koid, pin: pinned, base: iova, bytes: span.bytes, phase: .mapped))
      if count == entries.count { entries.append(entry) } else { entries[count] = entry }
      count += 1
      if !mapPinned(koid, iova, pinned, span) { return .quarantined(serial) }
      entries[count - 1].visible = true
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
        entries[i].visible = false
        if !entries[i].retirement.retire(detach, invalidate, drainAtcs, unpin) { return false }
        count -= 1
        entries[i] = entries[count]
        return true
      }
    }
    return false
  }

  public init(
    group: UInt64, koid: UInt64, epoch: UInt64, aperture: DeviceRange, page: UInt64, limit: Int
  ) {
    self.group = group
    self.koid = koid
    self.epoch = epoch
    self.aperture = aperture
    self.page = page
    self.limit = limit
  }
}
