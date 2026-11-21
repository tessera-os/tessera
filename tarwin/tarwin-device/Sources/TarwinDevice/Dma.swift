// The domain lock covers allocation, installation and retirement. Retiring
// intervals stay in occupied until the invalidation sequence completes.
public enum DmaAddress: Equatable {
  case unavailable
  case selected(UInt64)
}

public func chooseDmaAddress(
  _ aperture: DeviceRange, _ bytes: UInt64, _ pageSize: UInt64, _ randomWord: UInt64,
  _ occupied: [DeviceRange]
) -> DmaAddress {
  if !aperture.valid() || bytes == 0 || bytes > aperture.length { return .unavailable }
  if !deviceAligned(aperture.base, pageSize) || !deviceAligned(bytes, pageSize) {
    return .unavailable
  }
  let last = (aperture.length - bytes) / pageSize
  // last cannot be UInt64.max: bytes consumes at least one page.
  let choices = last + 1
  // Drop the biased tail rather than favor low IOVAs.
  let excess = (UInt64(0) &- choices) % choices
  if randomWord < excess { return .unavailable }
  let address = aperture.base + (randomWord % choices) * pageSize
  let candidate = DeviceRange(base: address, length: bytes)
  for range in occupied {
    if !range.valid() || range.overlaps(candidate) { return .unavailable }
  }
  return .selected(address)
}

// Trusted composition supplies synchronous IOMMU operations. A timeout
// leaves both pages and address quarantined. No driver callback can free them.
public enum DmaRetirePhase: Equatable {
  case mapped
  case detached
  case ioFlushed
  case deviceFlushed
  case released
}

public struct DmaRetirement: Equatable {
  public let domain: UInt64
  public let pin: UInt64
  public let base: UInt64
  public let bytes: UInt64
  public internal(set) var phase: DmaRetirePhase

  public mutating func retire(
    _ detach: (UInt64, UInt64, UInt64) -> Bool, _ invalidateIo: (UInt64, UInt64, UInt64) -> Bool,
    _ invalidateAtcs: (UInt64, UInt64, UInt64) -> Bool, _ unpin: (UInt64) -> Void
  ) -> Bool {
    if phase == .mapped {
      if !detach(domain, base, bytes) { return false }
      phase = .detached
    }
    if phase == .detached {
      if !invalidateIo(domain, base, bytes) { return false }
      phase = .ioFlushed
    }
    if phase == .ioFlushed {
      if !invalidateAtcs(domain, base, bytes) { return false }
      phase = .deviceFlushed
    }
    if phase == .deviceFlushed {
      unpin(pin)
      phase = .released
    }
    return phase == .released
  }

  public init(domain: UInt64, pin: UInt64, base: UInt64, bytes: UInt64, phase: DmaRetirePhase) {
    self.domain = domain
    self.pin = pin
    self.base = base
    self.bytes = bytes
    self.phase = phase
  }
}
