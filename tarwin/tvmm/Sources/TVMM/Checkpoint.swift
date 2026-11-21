// Live migration is a single-owner handoff. Transport callbacks must be authenticated,
// bound to this transfer's epoch, and durable before commit. A lost ACK is not an abort.
public enum TransferPhase {
  case running, precopy, stopped, captured, prepared, committed, retired, aborted
}
public struct Checkpoint {
  public let epoch: UInt64
  public let requiredDevices: UInt64
  public let requiredCpus: UInt64
  public internal(set) var phase: TransferPhase = .running
  public internal(set) var nextCpu: UInt64 = 0
  public internal(set) var savedDevices: UInt64 = 0

  public init(epoch: UInt64, requiredDevices: UInt64, requiredCpus: UInt64) {
    self.epoch = epoch
    self.requiredDevices = requiredDevices
    self.requiredCpus = requiredCpus
  }

  public mutating func start(_ generation: UInt64) -> Bool {
    if generation != epoch || phase != .running || requiredCpus == 0 || requiredCpus > 512 {
      return false
    }
    phase = .precopy
    return true
  }
  public mutating func stopped(_ cpusExited: Bool, _ dmaDrained: Bool, _ inputsFrozen: Bool) -> Bool
  {
    if phase != .precopy || !cpusExited || !dmaDrained || !inputsFrozen { return false }
    phase = .stopped
    return true
  }
  public mutating func cpuSaved(_ index: UInt64) -> Bool {
    if phase != .stopped || index != nextCpu || index >= requiredCpus { return false }
    nextCpu += 1
    return true
  }
  public mutating func devicesSaved(_ mask: UInt64) -> Bool {
    if phase != .stopped || (mask & requiredDevices) != mask { return false }
    savedDevices = savedDevices | mask
    return true
  }
  public mutating func seal(_ finalDirtyCopied: Bool, _ irqTimerSaved: Bool, _ cloneDurable: Bool)
    -> Bool
  {
    if phase != .stopped || !finalDirtyCopied || !irqTimerSaved || !cloneDurable
      || nextCpu != requiredCpus || savedDevices != requiredDevices
    {
      return false
    }
    phase = .captured
    return true
  }
  public mutating func prepared(_ generation: UInt64, _ destinationVerified: Bool) -> Bool {
    if generation != epoch || phase != .captured || !destinationVerified { return false }
    phase = .prepared
    return true
  }
  public mutating func commit(_ sourceFenced: Bool, _ decisionDurable: Bool) -> Bool {
    if phase != .prepared || !sourceFenced || !decisionDurable { return false }
    phase = .committed
    return true
  }
  public mutating func retired(_ generation: UInt64) -> Bool {
    if generation != epoch || phase != .committed { return false }
    phase = .retired
    return true
  }
  public mutating func abort() -> Bool {
    if phase == .committed || phase == .retired || phase == .aborted { return false }
    phase = .aborted
    nextCpu = 0
    savedDevices = 0
    return true
  }
}
