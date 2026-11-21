public enum ArmWatchdogFrame { case control, refresh }

/// Exclusive kernel mappings from the board's verified watchdog description.
/// Operations are ordered, aligned 32-bit device accesses.
public protocol ArmWatchdogIO {
  mutating func read(_ frame: ArmWatchdogFrame, _ offset: UInt32) -> UInt32
  mutating func write(_ frame: ArmWatchdogFrame, _ offset: UInt32, _ value: UInt32)
}

/// SBSA generic watchdog. A stage lasts `offset` system-counter ticks;
/// two consecutive expired stages request reset. Never disable or take
/// over a watchdog already owned by firmware.
public struct ArmGenericWatchdog<Bus: ArmWatchdogIO>: ~Copyable {
  private var bus: Bus
  private var lastDispatch: UInt64

  public init?(bus: consuming Bus, offset: UInt64, dispatch: UInt64) {
    var io = consume bus
    guard offset > 0 else { return nil }
    let id = io.read(.control, 0xfcc), version = (id >> 16) & 0xf
    guard id & 0xfff != 0, id == io.read(.refresh, 0xfcc), version <= 1,
      offset <= (version == 0 ? 0xffff_ffff : 0xffff_ffff_ffff),
      io.read(.control, 0) == 0 else { return nil }
    if version == 1 { io.write(.control, 0xc, UInt32(offset >> 32)) }
    let low = UInt32(truncatingIfNeeded: offset)
    io.write(.control, 8, low)
    guard io.read(.control, 8) == low,
      version == 0 || io.read(.control, 0xc) == UInt32(offset >> 32) else { return nil }
    io.write(.control, 0, 1)
    guard io.read(.control, 0) == 1 else { return nil }
    self.bus = consume io
    lastDispatch = dispatch
  }

  /// Single monitored scheduler, same non-wrapping counter epoch as at
  /// startup. Pass the sample from a completed scheduling decision, not
  /// the watchdog interrupt's time. Never refresh after a warning.
  public mutating func service(dispatch: UInt64) -> Bool {
    guard dispatch > lastDispatch, bus.read(.control, 0) == 1 else { return false }
    bus.write(.refresh, 0, 0)
    lastDispatch = dispatch
    return bus.read(.control, 0) == 1
  }
}
