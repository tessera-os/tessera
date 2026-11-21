public struct RegisteredReceive: Equatable {
  public let process: UInt64
  public let key: UInt64
  public let memory: UInt64
  public let offset: UInt64
  public let length: UInt32

  public init(process: UInt64, key: UInt64, memory: UInt64, offset: UInt64, length: UInt32) {
    self.process = process
    self.key = key
    self.memory = memory
    self.offset = offset
    self.length = length
  }
}
public enum ReceiveResult: Equatable {
  case noMatch
  case policyDenied
  case wouldBlock
  case fault
  case delivered(UInt32)
}

func addressMatches(_ bytes: [UInt8], _ at: Int, _ width: Int, _ bound: [UInt8]) -> Bool {
  if bound.count == 0 { return true }
  if bound.count != width { return false }
  for i in 0..<width { if bound[i] != bytes[at + i] { return false } }
  return true
}

// Per bound UDP endpoint; peer matching and policy are checked before a
// posted receive can be consumed. The VM pins exactly the registered range;
// teardown owns the unpin. Publish completions under the port credit contract.
public struct UdpEndpoint: Equatable {
  public let process: UInt64
  public let family: IpFamily
  public let port: UInt16
  public let limit: Int
  public var local: [UInt8] = []
  public var peer: [UInt8] = []
  public var peerPort: UInt16 = 0
  public var interfaceId: UInt64 = 0
  public internal(set) var receives: [RegisteredReceive] = []
  public internal(set) var first: Int = 0
  public internal(set) var count: Int = 0
  public internal(set) var closed: Bool = false

  public mutating func post(
    _ r: RegisteredReceive, _ pinWritable: (UInt64, UInt64, UInt64, UInt32) -> Bool
  ) -> Bool {
    if closed || r.process != process || r.memory == 0 || r.key == 0 || r.length == 0
      || count >= limit || UInt64(r.length - 1) > 0xffff_ffff_ffff_ffff - r.offset
    {
      return false
    }
    for i in 0..<count { if receives[(first + i) % limit].key == r.key { return false } }
    if !pinWritable(process, r.memory, r.offset, r.length) { return false }
    let index = (first + count) % limit
    if index == receives.count { receives.append(r) } else { receives[index] = r }
    count += 1
    return true
  }

  public mutating func deliver(
    _ bytes: [UInt8], _ iface: UInt64, _ permitted: (UInt64, UInt64, [UInt8]) -> Bool,
    _ writePinned: (RegisteredReceive, [UInt8], Int, Int) -> Bool,
    _ done: (RegisteredReceive, UInt32, Bool) -> Void
  ) -> ReceiveResult {
    if closed { return .noMatch }
    switch decodeUdp(bytes) {
    case .accepted(let d):
      guard matches(d, bytes, iface) else { return .noMatch }
      if !permitted(process, iface, bytes) { return .policyDenied }
      if count == 0 { return .wouldBlock }
      let r = receives[first]
      let n = d.length > Int(r.length) ? Int(r.length) : d.length
      let copied = writePinned(r, bytes, d.payload, n)
      count -= 1
      first = (first + 1) % limit
      done(r, copied ? UInt32(n) : 0, copied)
      if !copied { return .fault }
      return .delivered(UInt32(n))
    default: return .noMatch
    }
  }
  func matches(_ d: Datagram, _ bytes: [UInt8], _ iface: UInt64) -> Bool {
    let width = d.family == .v4 ? 4 : 16
    let start = d.family == .v4 ? 12 : 8
    return d.family == family && d.destinationPort == port
      && (interfaceId == 0 || interfaceId == iface) && (peerPort == 0 || peerPort == d.sourcePort)
      && addressMatches(bytes, start, width, peer)
      && addressMatches(bytes, start + width, width, local)
  }

  public mutating func shutdown(_ cancel: (RegisteredReceive) -> Void) {
    closed = true
    while count > 0 {
      cancel(receives[first])
      first = (first + 1) % limit
      count -= 1
    }
  }

  public init(process: UInt64, family: IpFamily, port: UInt16, limit: Int) {
    self.process = process
    self.family = family
    self.port = port
    self.limit = limit
  }
}
