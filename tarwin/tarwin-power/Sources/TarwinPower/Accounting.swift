public struct ProcessEnergy: Equatable {
  public internal(set) var microjoules: UInt64 = 0
  public internal(set) var fraction: UInt64 = 0

  public mutating func addDevice(_ amount: UInt64) {
    if amount > 0xffff_ffff_ffff_ffff - microjoules {
      microjoules = 0xffff_ffff_ffff_ffff
    } else {
      microjoules += amount
    }
  }

  public mutating func addCpu(_ nanos: UInt64, _ microwatts: UInt32) {
    let power = UInt64(microwatts)
    let seconds = nanos / 1_000_000_000
    if power == 0 { return }
    if seconds > 0xffff_ffff_ffff_ffff / power {
      microjoules = 0xffff_ffff_ffff_ffff
      return
    }
    addDevice(seconds * power)
    let sub = (nanos % 1_000_000_000) * power + fraction
    addDevice(sub / 1_000_000_000)
    fraction = sub % 1_000_000_000
  }

  public init() {
  }
}

public enum ThermalBand: Equatable {
  case nominal
  case fair
  case serious
  case critical
}
public struct ThermalZone: Equatable {
  public let millidegrees: Int
  public let fair: Int
  public let serious: Int
  public let critical: Int

  public init(millidegrees: Int, fair: Int, serious: Int, critical: Int) {
    self.millidegrees = millidegrees
    self.fair = fair
    self.serious = serious
    self.critical = critical
  }
}
private func thermalLevel(_ z: ThermalZone) -> Int {
  if z.fair >= z.serious || z.serious >= z.critical || z.millidegrees >= z.critical { return 3 }
  if z.millidegrees >= z.serious { return 2 }
  if z.millidegrees >= z.fair { return 1 }
  return 0
}
public func thermalBand(_ zones: [ThermalZone], skin: ThermalZone? = nil) -> ThermalBand {
  var level = skin.map(thermalLevel) ?? 0
  for zone in zones { level = max(level, thermalLevel(zone)) }
  switch level {
  case 3: return .critical
  case 2: return .serious
  case 1: return .fair
  default: return .nominal
  }
}
