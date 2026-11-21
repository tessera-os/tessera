// The firmware host-bridge descriptor owns an ECAM segment. The accessor
// returns all ones on an absent function or platform-reported access fault.
public struct PciFunction: Equatable {
  public let bus: UInt32
  public let device: UInt32
  public let functionNumber: UInt32
  public let identity: UInt32
  public let classRevision: UInt32
  public let parent: Int

  public init(
    bus: UInt32, device: UInt32, functionNumber: UInt32, identity: UInt32, classRevision: UInt32,
    parent: Int
  ) {
    self.bus = bus
    self.device = device
    self.functionNumber = functionNumber
    self.identity = identity
    self.classRevision = classRevision
    self.parent = parent
  }
}

private struct PciBus {
  var number: UInt8 = 0, last: UInt8 = 0, parent: Int32 = -1
}
/// Reusable scratch owned by the discovery worker, not the interrupt stack.
public struct PciWalkScratch: ~Copyable {
  fileprivate var buses = InlineArray<256, PciBus>(repeating: PciBus())
  public init() {}
}

/// Breadth-first walk of reachable buses in one host bridge. Parent indices
/// refer to earlier visits. A visitor refusing a function stops all further
/// reads; the caller must discard the incomplete snapshot.
public func visitEcam(
  _ firstBus: UInt32, _ lastBus: UInt32, scratch: inout PciWalkScratch,
  read32: (UInt32) -> UInt32, visit: (PciFunction) -> Bool
) -> Bool {
  guard firstBus <= lastBus, lastBus <= 255 else { return false }
  var bits = InlineArray<4, UInt64>(repeating: 0)
  scratch.buses[0] = PciBus(number: UInt8(firstBus), last: UInt8(lastBus), parent: -1)
  bits[Int(firstBus / 64)] |= 1 << (firstBus % 64)
  var next = 0
  var queued = 1
  var found = 0
  while next < queued {
    let bus = scratch.buses[next]
    next += 1
    for dev in 0..<32 {
      var fun: UInt32 = 0
      var count: UInt32 = 1
      while fun < count {
        let base = ((UInt32(bus.number) - firstBus) << 20) | (UInt32(dev) << 15) | (fun << 12)
        let id = read32(base)
        if (id & 0xffff) != 0xffff {
          let header = (read32(base + 12) >> 16) & 0xff
          if fun == 0 && (header & 0x80) != 0 { count = 8 }
          let classRev = read32(base + 8)
          let parentIndex = found
          guard
            visit(
              PciFunction(
                bus: UInt32(bus.number), device: UInt32(dev), functionNumber: fun,
                identity: id, classRevision: classRev, parent: Int(bus.parent)))
          else { return false }
          found += 1
          if (header & 0x7f) == 1 && (classRev >> 16) == 0x0604 {
            let buses = read32(base + 24)
            let secondary = (buses >> 8) & 0xff
            let subordinate = (buses >> 16) & 0xff
            if (buses & 0xff) == UInt32(bus.number) && secondary > UInt32(bus.number)
              && subordinate >= secondary
              && subordinate <= UInt32(bus.last)
              && bits[Int(secondary / 64)] & (1 << (secondary % 64)) == 0
            {
              bits[Int(secondary / 64)] |= 1 << (secondary % 64)
              scratch.buses[queued] = PciBus(
                number: UInt8(secondary), last: UInt8(subordinate), parent: Int32(parentIndex))
              queued += 1
            }
          }
        }
        fun += 1
      }
    }
  }
  return true
}
