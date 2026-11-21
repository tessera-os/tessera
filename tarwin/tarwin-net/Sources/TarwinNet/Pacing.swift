// Each flow contributes only its FIFO head. The finish tag is local to
// the interface, in bytes of service; after an idle period a flow starts
// at the current virtual time instead of banking credit.
public struct FlowHead: Equatable {
  public let notBefore: UInt64
  public let background: Bool
  public let finish: UInt64
  public let ordinal: UInt64

  public init(notBefore: UInt64, background: Bool, finish: UInt64, ordinal: UInt64) {
    self.notBefore = notBefore
    self.background = background
    self.finish = finish
    self.ordinal = ordinal
  }
}

public func flowFinish(_ last: UInt64, _ virtualTime: UInt64, _ bytes: UInt32) -> UInt64 {
  let start = last > virtualTime ? last : virtualTime
  if UInt64(bytes) > 0xffff_ffff_ffff_ffff - start { return 0xffff_ffff_ffff_ffff }
  return start + UInt64(bytes)
}

public func nextFlow(_ heads: [FlowHead], _ now: UInt64, _ congested: Bool) -> Int {
  var best: Int = -1
  for i in 0..<heads.count {
    let head = heads[i]
    if head.notBefore > now { continue }
    if best >= 0 {
      let old = heads[best]
      if congested && old.background != head.background {
        if head.background { continue }
      } else if head.finish > old.finish
        || (head.finish == old.finish && head.ordinal >= old.ordinal)
      {
        continue
      }
    }
    best = Int(i)
  }
  return best
}
