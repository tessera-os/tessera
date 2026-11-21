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

struct PciBus: Equatable {
  let number: UInt32
  let last: UInt32
  let parent: Int
}

public func enumerateEcam(_ firstBus: UInt32, _ lastBus: UInt32, _ read32: (UInt32) -> UInt32)
  -> [PciFunction]
{
  var found: [PciFunction] = []
  if lastBus > 255 || firstBus > lastBus { return found }
  var work = [PciBus(number: firstBus, last: lastBus, parent: -1)]
  var visited: [Bool] = []
  for _ in 0..<256 { visited.append(false) }
  visited[Int(firstBus)] = true
  var next: Int = 0
  while next < work.count {
    let bus = work[next]
    next += 1
    for dev in 0..<32 {
      var fun: UInt32 = 0
      var count: UInt32 = 1
      while fun < count {
        let base = ((bus.number - firstBus) << 20) | (UInt32(dev) << 15) | (fun << 12)
        let id = read32(base)
        if (id & 0xffff) != 0xffff {
          let header = (read32(base + 12) >> 16) & 0xff
          if fun == 0 && (header & 0x80) != 0 { count = 8 }
          let classRev = read32(base + 8)
          let parentIndex = Int(found.count)
          found.append(
            PciFunction(
              bus: bus.number, device: UInt32(dev), functionNumber: fun,
              identity: id, classRevision: classRev, parent: bus.parent))
          if (header & 0x7f) == 1 && (classRev >> 16) == 0x0604 {
            let buses = read32(base + 24)
            let secondary = (buses >> 8) & 0xff
            let subordinate = (buses >> 16) & 0xff
            if (buses & 0xff) == bus.number && secondary > bus.number && subordinate >= secondary
              && subordinate <= bus.last && !visited[Int(secondary)]
            {
              visited[Int(secondary)] = true
              work.append(PciBus(number: secondary, last: subordinate, parent: parentIndex))
            }
          }
        }
        fun += 1
      }
    }
  }
  return found
}
