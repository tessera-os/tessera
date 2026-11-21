// One record per inseparable IOMMU group, held under the registry lock.
public enum SlotPhase: Equatable {
  case vacant
  case active
  case masking
  case unmapping
  case draining
  case resetting
  case removed
}
public struct DeviceSlotState: Equatable {
  public let group: UInt64
  public internal(set) var phase: SlotPhase = .vacant
  public internal(set) var owner: UInt64 = 0
  public internal(set) var epoch: UInt64 = 0
  public internal(set) var vanished: Bool = false

  // The group-domain provider attaches every member and establishes
  // interrupt remapping before it reports success; failure stays isolated.
  public mutating func assign(
    _ deviceRoot: Bool, _ process: UInt64, _ isolateGroup: (UInt64, UInt64) -> Bool
  ) -> Bool {
    if !deviceRoot || process == 0 || phase != .vacant || epoch == 0xffff_ffff_ffff_ffff {
      return false
    }
    if !isolateGroup(group, epoch + 1) { return false }
    epoch += 1
    owner = process
    phase = .active
    return true
  }

  public func owns(_ process: UInt64, _ generation: UInt64) -> Bool {
    return phase == .active && owner == process && epoch == generation
  }

  // Callbacks complete synchronously and are idempotent on failure. Block
  // all new operations immediately, including config writes and doorbells.
  public mutating func revoke(
    _ removed: Bool, _ maskAndDrainIrqs: () -> Bool, _ revokeCpuMappings: () -> Bool,
    _ retireAllDma: () -> Bool, _ resetGroup: () -> Bool
  ) -> Bool {
    vanished = vanished || removed
    if phase == .removed { return true }
    if phase == .vacant {
      if vanished { phase = .removed }
      return true
    }
    if phase == .active { phase = .masking }
    if phase == .masking {
      if !maskAndDrainIrqs() { return false }
      phase = .unmapping
    }
    if phase == .unmapping {
      if !revokeCpuMappings() { return false }
      phase = .draining
    }
    if phase == .draining {
      if !retireAllDma() { return false }
      phase = .resetting
    }
    if !vanished && !resetGroup() { return false }
    phase = vanished ? SlotPhase.removed : SlotPhase.vacant
    owner = 0
    return true
  }

  public init(group: UInt64) {
    self.group = group
  }
}

public enum DeviceCache: Equatable {
  case register
  case frameBuffer
}
public struct MmioAperture: Equatable {
  public let range: DeviceRange
  public let frameBuffer: Bool

  public init(range: DeviceRange, frameBuffer: Bool) {
    self.range = range
    self.frameBuffer = frameBuffer
  }
}

// The platform supplies device attributes for registers, WC only for a
// trusted framebuffer, and rejects a mapping if NX cannot be enforced.
public func mapSlotRegisters(
  _ slot: DeviceSlotState, _ process: UInt64, _ generation: UInt64, _ region: MmioAperture,
  _ bytes: DeviceRange, _ pageSize: UInt64, _ cache: DeviceCache,
  _ recordAndMapNx: (UInt64, UInt64, UInt64, DeviceCache) -> Bool
) -> Bool {
  if !slot.owns(process, generation) || !region.range.contains(bytes)
    || !deviceAligned(bytes.base, pageSize) || !deviceAligned(bytes.length, pageSize)
    || (cache == .frameBuffer && !region.frameBuffer)
  {
    return false
  }
  return recordAndMapNx(process, bytes.base, bytes.length, cache)
}
