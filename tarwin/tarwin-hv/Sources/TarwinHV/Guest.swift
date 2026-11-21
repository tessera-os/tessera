// §23. Policy inputs come from kernel-owned objects and the intersection of host CPU capabilities.
public enum HvError: Error {
  case ok, accessDenied, featureUnavailable, invalid, limit, busy, wrongThread
}

public struct GuestCapabilities {
  public let stageTwo: Bool
  public let interruptController: Bool
  public let architecturalTimer: Bool
  public let nested: Bool
  public let confidential: Bool
  public let attestation: Bool
  public let nestedConfidential: Bool
  public let addressBits: UInt64
  public let cpuFeatures: UInt64

  public init(
    stageTwo: Bool, interruptController: Bool, architecturalTimer: Bool, nested: Bool,
    confidential: Bool, attestation: Bool, nestedConfidential: Bool, addressBits: UInt64,
    cpuFeatures: UInt64
  ) {
    self.stageTwo = stageTwo
    self.interruptController = interruptController
    self.architecturalTimer = architecturalTimer
    self.nested = nested
    self.confidential = confidential
    self.attestation = attestation
    self.nestedConfidential = nestedConfidential
    self.addressBits = addressBits
    self.cpuFeatures = cpuFeatures
  }
}

public func admitGuest(
  _ host: GuestCapabilities, _ bits: UInt64, _ features: UInt64, _ nested: Bool,
  _ confidential: Bool, _ hasEntitlement: Bool, _ hasResource: Bool,
  _ liveMachines: UInt64
) -> HvError {
  if !hasEntitlement && !hasResource { return .accessDenied }
  if liveMachines >= 64 { return .limit }
  if bits == 0 || bits > 63 { return .invalid }
  if !host.stageTwo || !host.interruptController || !host.architecturalTimer
    || bits > host.addressBits || (features & host.cpuFeatures) != features
    || (nested && !host.nested) || (confidential && (!host.confidential || !host.attestation))
    || (nested && confidential && !host.nestedConfidential)
  {
    return .featureUnavailable
  }
  return .ok
}

public func admitAssignment(
  _ hasResource: Bool, _ hasSlotGrant: Bool, _ nestedDma: Bool,
  _ postedInterrupts: Bool, _ isolatedMmio: Bool
) -> HvError {
  if !hasResource && !hasSlotGrant { return .accessDenied }
  if !nestedDma || !postedInterrupts || !isolatedMmio { return .featureUnavailable }
  return .ok
}

// Subtraction-based half-open range checks; no wrapped end address or rounded partial page.
public func validGuestRange(_ base: UInt64, _ length: UInt64, _ limit: UInt64, _ page: UInt64)
  -> Bool
{
  if (page != 4096 && page != 16384) || length == 0 || base > limit { return false }
  return base % page == 0 && length % page == 0 && length <= limit - base
}

public func validMapping(
  _ guest: UInt64, _ offset: UInt64, _ length: UInt64, _ guestLimit: UInt64,
  _ memorySize: UInt64, _ page: UInt64, _ requested: UInt64, _ allowed: UInt64
) -> Bool {
  return requested != 0 && requested <= 7 && (requested & allowed) == requested
    && validGuestRange(guest, length, guestLimit, page)
    && validGuestRange(offset, length, memorySize, page)
}

public func overlapsGuest(_ a: UInt64, _ sizeA: UInt64, _ b: UInt64, _ sizeB: UInt64) -> Bool {
  if sizeA == 0 || sizeB == 0 { return false }
  if a <= b { return b - a < sizeA }
  return a - b < sizeB
}

// Fold a write-trap or hardware dirty interval into one word of the GPA-indexed dirty bitmap.
public func dirtyWord(_ firstPage: UInt64, _ dirtyFirst: UInt64, _ dirtyCount: UInt64) -> UInt64 {
  var result: UInt64 = 0
  var bit: UInt64 = 0
  while bit < 64 && bit <= 0xffff_ffff_ffff_ffff - firstPage {
    let page = firstPage + bit
    if page >= dirtyFirst && page - dirtyFirst < dirtyCount { result = result | (UInt64(1) << bit) }
    bit += 1
  }
  return result
}

public enum GuestExit {
  case mmio, portIo, hypercall, systemRegister, wait, exception, debug, shutdown, reset, canceled
}
public enum RunAction { case enter, cancel, deny, busy }
public struct VirtualCpuState {
  public let creator: UInt64
  public internal(set) var running: Bool = false
  public internal(set) var exitRequested: Bool = false

  public init(creator: UInt64) {
    self.creator = creator
  }

  // The vCPU lock serializes these transitions with kicking the CPU on which it was published.
  public mutating func begin(_ thread: UInt64) -> RunAction {
    if thread != creator { return .deny }
    if running { return .busy }
    if exitRequested {
      exitRequested = false
      return .cancel
    }
    running = true
    return .enter
  }
  public mutating func requestExit() -> Bool {
    exitRequested = true
    return running
  }
  public mutating func finish(_ reason: GuestExit) -> GuestExit {
    running = false
    if exitRequested {
      exitRequested = false
      return .canceled
    }
    return reason
  }
}

public func admitVcpu(_ index: UInt64, _ present: Bool, _ count: UInt64, _ hostCount: UInt64)
  -> HvError
{
  if index >= 512 || count >= 512 || count >= hostCount { return .limit }
  if present { return .busy }
  return .ok
}
