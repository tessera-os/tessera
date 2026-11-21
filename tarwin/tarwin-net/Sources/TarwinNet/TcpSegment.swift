public struct SackBlock: Equatable {
  public let left: UInt32, right: UInt32
  public init?(left: UInt32, right: UInt32) {
    let span = right &- left
    guard span != 0, span < (1 << 31) else { return nil }
    self.left = left
    self.right = right
  }
}
public struct TcpOptions {
  public fileprivate(set) var mss: UInt16?, scale: UInt8?, sackPermitted = false,
    sacks: [SackBlock] = []
  public fileprivate(set) var timestamp: UInt32?, timestampEcho: UInt32?
}
public struct TcpSegment {
  public let family: IpFamily, source: [UInt8], destination: [UInt8], sourcePort: UInt16,
    destinationPort: UInt16
  public let sequence: UInt32, ack: UInt32, flags: UInt8, window: UInt16, options: TcpOptions
  public let payload: ArraySlice<UInt8>
}
private func tcpLong(_ b: [UInt8], _ at: Int) -> UInt32 { word(b, at) << 16 | word(b, at + 2) }
/// Complete IP packet, without Ethernet. No checksum-offload exemption:
/// fragments, IP options and IPv6 extension headers require earlier processing.
public func tcpSegment(_ b: [UInt8]) -> TcpSegment? {
  guard !b.isEmpty else { return nil }
  let start: Int
  let ip: Int
  let end: Int
  let width: Int
  let family: IpFamily
  if b[0] == 0x45 {
    guard b.count >= 40, b[9] == 6, word(b, 6) & 0xbfff == 0, sumBytes(b, 0, 20, 0) == 0xffff else {
      return nil
    }
    ip = 20
    end = Int(word(b, 2))
    start = 12
    width = 4
    family = .v4
  } else if b[0] >> 4 == 6 {
    guard b.count >= 60, b[6] == 6 else { return nil }
    ip = 40
    end = 40 + Int(word(b, 4))
    start = 8
    width = 16
    family = .v6
  } else {
    return nil
  }
  guard end <= b.count, end >= ip + 20 else { return nil }
  let header = Int(b[ip + 12] >> 4) * 4
  let flags = b[ip + 13]
  guard header >= 20, header <= end - ip else { return nil }
  var sum = sumBytes(b, start, width * 2, 0) + UInt32(end - ip) + 6
  sum = (sum & 0xffff) + (sum >> 16)
  guard sumBytes(b, ip, end - ip, sum) == 0xffff else { return nil }
  let syn = flags & 2 != 0
  var opt = TcpOptions()
  var at = ip + 20
  while at < ip + header {
    let kind = b[at]
    if kind == 0 {
      guard b[at..<ip + header].allSatisfy({ $0 == 0 }) else { return nil }
      break
    }
    if kind == 1 {
      at += 1
      continue
    }
    guard at + 2 <= ip + header else { return nil }
    let n = Int(b[at + 1])
    guard n >= 2, at + n <= ip + header else { return nil }
    switch kind {
    case 2:
      guard n == 4 else { return nil }
      if syn {
        guard opt.mss == nil, word(b, at + 2) > 0 else { return nil }
        opt.mss = UInt16(word(b, at + 2))
      }
    case 3:
      guard n == 3 else { return nil }
      if syn {
        guard opt.scale == nil else { return nil }
        opt.scale = min(14, b[at + 2])
      }
    case 4:
      guard n == 2 else { return nil }
      if syn {
        guard !opt.sackPermitted else { return nil }
        opt.sackPermitted = true
      }
    case 5:
      guard n >= 10, n % 8 == 2, !syn, flags & 16 != 0, opt.sacks.isEmpty else { return nil }
      for i in stride(from: at + 2, to: at + n, by: 8) {
        guard let s = SackBlock(left: tcpLong(b, i), right: tcpLong(b, i + 4)) else { return nil }
        opt.sacks.append(s)
      }
    case 8:
      guard n == 10, opt.timestamp == nil else { return nil }
      opt.timestamp = tcpLong(b, at + 2)
      opt.timestampEcho = tcpLong(b, at + 6)
    default: break
    }
    at += n
  }
  return TcpSegment(
    family: family, source: Array(b[start..<start + width]),
    destination: Array(b[start + width..<start + 2 * width]),
    sourcePort: UInt16(word(b, ip)), destinationPort: UInt16(word(b, ip + 2)),
    sequence: tcpLong(b, ip + 4), ack: tcpLong(b, ip + 8),
    flags: flags, window: UInt16(word(b, ip + 14)), options: opt, payload: b[ip + header..<end])
}
