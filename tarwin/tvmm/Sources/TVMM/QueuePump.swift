// Precondition: configure one pump for each validated, pinned split queue.
// The acquire/publish callbacks operate on that queue's guest pages only. A
// backend returns after I/O is complete; a failed operation with a virtio status
// still returns its used length. A transport failure instead breaks the queue.
public enum PumpResult { case drained, progress, broken }
public struct QueuePump {
  public let slots: Int
  public internal(set) var nextAvail: UInt64 = 0
  public internal(set) var nextUsed: UInt64 = 0
  public internal(set) var broken: Bool = false

  public init(slots: Int) {
    self.slots = slots
  }

  public mutating func serviceOne(
    _ ram: GuestAperture,
    _ acquireAvailable: () -> UInt64, _ readHead: (UInt64) -> UInt64,
    _ snapshotTable: () -> [UInt8],
    _ execute: ([Segment]) -> UInt64,
    _ writeUsed: (UInt64, UInt64, UInt64) -> Void, _ releaseUsed: (UInt64) -> Void
  ) -> PumpResult {
    if broken { return .broken }
    let available = acquireAvailable()
    if slots < 1 || slots > 32768 || (Int(slots) & (Int(slots) - 1)) != 0 || available > 65535 {
      broken = true
      return .broken
    }
    let pending = (65536 + available - nextAvail) & 65535
    if pending == 0 { return .drained }
    if pending > UInt64(slots) {
      broken = true
      return .broken
    }
    let head = readHead(nextAvail % UInt64(slots))
    if head >= UInt64(slots) {
      broken = true
      return .broken
    }
    let segments: [Segment]
    switch descriptorChain(snapshotTable(), slots, Int(head), ram) {
    case .success(let s): segments = s
    case .failure:
      broken = true
      return .broken
    }
    var maxUsed: UInt64 = 0
    for s in segments { if s.writable { maxUsed += s.length } }
    let used = execute(segments)
    if used > maxUsed || used > 0xffff_ffff {
      broken = true
      return .broken
    }
    writeUsed(nextUsed % UInt64(slots), head, used)
    nextUsed = (nextUsed + 1) & 65535
    nextAvail = (nextAvail + 1) & 65535
    releaseUsed(nextUsed)
    return .progress
  }
}

public struct ModernVirtio {
  public let offered: UInt64
  public internal(set) var accepted: UInt64 = 0
  public internal(set) var status: UInt64 = 0

  public init(offered: UInt64) {
    self.offered = offered
  }

  public mutating func negotiate(_ bits: UInt64) -> Bool {
    if status != 3 || (bits & offered) != bits || (bits & 0x1_0000_0000) == 0 { return false }
    accepted = bits
    return true
  }
  public mutating func writeStatus(_ value: UInt64, _ drainAndReset: () -> Bool) -> Bool {
    if value == 0 {
      if !drainAndReset() { return false }
      accepted = 0
      status = 0
      return true
    }
    if value > 255 || (value & status) != status || (value & 0x70) != 0 { return false }
    // The driver first acknowledges the device, then the driver, then its features.
    let next = value & 15
    if next != 1 && next != 3 && next != 11 && next != 15 { return false }
    if (value & 2) != 0 && (status & 1) == 0 { return false }
    if (value & 8) != 0 && ((status & 2) == 0 || (accepted & 0x1_0000_0000) == 0) { return false }
    if (value & 4) != 0 && (status & 8) == 0 { return false }
    status = value
    return true
  }
  public func ready() -> Bool { return status == 15 }
}
