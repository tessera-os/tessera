import TarwinArchHosted
import TarwinMM

public typealias HostedMemoryPressure = HostPressureLevel

public struct HostedPressureProcess: Sendable {
  public let id: UInt64
  public let band: UInt8
  public let footprint: UInt64
  public let limit: UInt64

  public init(id: UInt64, band: UInt8, footprint: UInt64, limit: UInt64) {
    self.id = id
    self.band = band
    self.footprint = footprint
    self.limit = limit
  }
}

public struct HostedJetsamEvent: Equatable, Sendable {
  public enum Reason: Equatable, Sendable { case pressure, footprintLimit }

  public let process: UInt64
  public let footprint: UInt64
  public let reason: Reason
}

public enum HostedJetsamResult: Equatable {
  case noAction
  case terminated(HostedJetsamEvent)
  case noEligibleProcess
}

public enum HostedJetsam {
  public static func enforceLimit(
    of process: HostedPressureProcess, terminate: (HostedJetsamEvent) throws -> Void
  ) rethrows -> HostedJetsamResult {
    guard process.id != 0,
      exceedsFootprint(process.band, bytes: process.footprint, limit: process.limit)
    else { return .noAction }
    let event = HostedJetsamEvent(
      process: process.id, footprint: process.footprint, reason: .footprintLimit)
    try terminate(event)
    return .terminated(event)
  }

  public static func handle(
    _ level: HostedMemoryPressure, processes: [HostedPressureProcess],
    signal: (UInt64, HostedMemoryPressure) -> Void,
    reclaimed: () throws -> Bool, terminate: (HostedJetsamEvent) throws -> Void
  ) rethrows -> HostedJetsamResult {
    guard level != .normal else { return .noAction }
    let ordered = processes.filter { $0.id != 0 && $0.band <= 6 }.sorted {
      $0.band != $1.band ? $0.band > $1.band : $0.id < $1.id
    }
    for process in ordered { signal(process.id, level) }
    let enough = try reclaimed()
    guard level == .critical, !enough else { return .noAction }
    let victim = ordered.reduce(noCandidate()) {
      selectVictim($0, next: PressureCandidate(koid: $1.id, band: $1.band, bytes: $1.footprint))
    }
    guard victim.koid != 0 else { return .noEligibleProcess }
    let event = HostedJetsamEvent(process: victim.koid, footprint: victim.bytes, reason: .pressure)
    try terminate(event)
    return .terminated(event)
  }
}
