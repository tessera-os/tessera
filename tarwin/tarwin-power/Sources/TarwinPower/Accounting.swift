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
