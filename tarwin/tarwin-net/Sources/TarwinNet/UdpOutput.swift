public struct UdpRoute: Equatable {
  public let family: IpFamily
  public let source: [UInt8]
  public let destination: [UInt8]
  public let sourcePort: UInt16
  public let destinationPort: UInt16
  public let hops: UInt8
  public let mtu: UInt32

  public init(
    family: IpFamily, source: [UInt8], destination: [UInt8], sourcePort: UInt16,
    destinationPort: UInt16, hops: UInt8, mtu: UInt32
  ) {
    self.family = family
    self.source = source
    self.destination = destination
    self.sourcePort = sourcePort
    self.destinationPort = destinationPort
    self.hops = hops
    self.mtu = mtu
  }
}
public enum OutputResult: Equatable {
  case invalid
  case tooLarge
  case packet([UInt8])
}

func putWord(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
  bytes[offset] = UInt8((value >> 8) & 255)
  bytes[offset + 1] = UInt8(value & 255)
}

public func udpOutput(_ route: UdpRoute, _ payload: [UInt8]) -> OutputResult {
  let v4 = route.family == .v4
  let width: Int = v4 ? 4 : 16
  let ip: Int = v4 ? 20 : 40
  if route.source.count != width || route.destination.count != width || route.destinationPort == 0
    || route.hops == 0
  {
    return .invalid
  }
  if payload.count > 65527 || (v4 && payload.count > 65507) { return .tooLarge }
  let udp = 8 + payload.count
  let total = ip + udp
  if UInt32(total) > route.mtu { return .tooLarge }
  var bytes: [UInt8] = []
  for i in 0..<(ip + 8) { bytes.append(0) }
  for byte in payload { bytes.append(byte) }
  var start: Int = 8
  if v4 {
    bytes[0] = 0x45
    putWord(&bytes, 2, UInt32(total))
    bytes[6] = 0x40
    bytes[8] = route.hops
    bytes[9] = 17
    start = 12
  } else {
    bytes[0] = 0x60
    putWord(&bytes, 4, UInt32(udp))
    bytes[6] = 17
    bytes[7] = route.hops
  }
  for i in 0..<width {
    bytes[start + i] = route.source[i]
    bytes[start + width + i] = route.destination[i]
  }
  if v4 { putWord(&bytes, 10, 0xffff ^ sumBytes(bytes, 0, 20, 0)) }
  putWord(&bytes, ip, UInt32(route.sourcePort))
  putWord(&bytes, ip + 2, UInt32(route.destinationPort))
  putWord(&bytes, ip + 4, UInt32(udp))
  let pseudo = sumBytes(bytes, start, width * 2, 0) + UInt32(udp) + 17
  let checksum = 0xffff ^ sumBytes(bytes, ip, udp, (pseudo & 0xffff) + (pseudo >> 16))
  putWord(&bytes, ip + 6, checksum == 0 ? 0xffff : checksum)
  return .packet(bytes)
}
