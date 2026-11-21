/// Board-certified maximum frequencies (Hz) and per-cluster dispatch
/// allowances (CPU-ns per window). Do not assume a particular OPP table.
public struct ClusterThermalLimits {
  let nominal: UInt64, fair: UInt64, serious: UInt64, critical: UInt64
  let window: UInt64, low: UInt64, medium: UInt64
  public init?(
    nominalHz: UInt64, fairHz: UInt64, seriousHz: UInt64, criticalHz: UInt64, windowNs: UInt64,
    utilityBackgroundNs: UInt64, nonInteractiveNs: UInt64
  ) {
    guard criticalHz > 0, criticalHz <= seriousHz, seriousHz <= fairHz, fairHz <= nominalHz,
      windowNs > 0,
      utilityBackgroundNs <= nonInteractiveNs, nonInteractiveNs <= windowNs
    else { return nil }
    nominal = nominalHz
    fair = fairHz
    serious = seriousHz
    critical = criticalHz
    window = windowNs
    low = utilityBackgroundNs
    medium = nonInteractiveNs
  }
}
public enum ThermalWork { case background, utility, standard, initiated, interactive, deadline }

/// Serialized with all dispatches for this cluster. A granted slice is a
/// conservative reservation, not a retrospective charge. Unused time is
/// never refunded by another CPU, policy change or QoS-class transition.
public struct ClusterGovernor: ~Copyable {
  private let limits: ClusterThermalLimits
  public private(set) var band: ThermalBand = .critical
  public private(set) var maximumHz: UInt64 = 0
  private var start: UInt64, last: UInt64, lowUsed: UInt64 = 0, mediumUsed: UInt64 = 0
  public init(limits: ClusterThermalLimits, now: UInt64) {
    self.limits = limits
    start = now
    last = now
  }
  public mutating func refresh(
    zones: [ThermalZone], skin: ThermalZone?, handheld: Bool, fresh: Bool,
    programMaximum: (UInt64) -> Bool
  ) -> Bool {
    if !fresh || zones.isEmpty || (handheld && skin == nil) {
      band = .critical
    } else {
      band = thermalBand(zones, skin: skin)
    }
    let hz: UInt64
    switch band {
    case .nominal: hz = limits.nominal
    case .fair: hz = limits.fair
    case .serious: hz = limits.serious
    case .critical: hz = limits.critical
    }
    maximumHz = 0
    guard programMaximum(hz) else { return false }
    maximumHz = hz
    return true
  }
  /// The caller preempts at the returned slice length. Every class observes
  /// the hardware maximum; interactive/deadline work is not quota-throttled.
  public mutating func reserve(_ work: ThermalWork, now: UInt64, wanted: UInt64) -> UInt64 {
    guard maximumHz > 0, now >= last else { return 0 }
    last = now
    let elapsed = now - start
    if elapsed >= limits.window {
      start = now - elapsed % limits.window
      lowUsed = 0
      mediumUsed = 0
    }
    var n = min(wanted, min(limits.window - (now - start), UInt64.max - now))
    switch work {
    case .interactive, .deadline: return n
    case .background, .utility:
      if band == .serious || band == .critical { n = min(n, limits.low - lowUsed) }
    case .standard, .initiated: break
    }
    if band == .critical { n = min(n, limits.medium - mediumUsed) }
    if work == .background || work == .utility { lowUsed += min(n, limits.low - lowUsed) }
    mediumUsed += min(n, limits.medium - mediumUsed)
    return n
  }
}
