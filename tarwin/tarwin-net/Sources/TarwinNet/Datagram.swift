// Offsets are relative to the IP header, not Ethernet. Fragments belong to
// reassembly and never reach an endpoint via this path.
public enum IpFamily: Equatable {
  case v4
  case v6
}
public struct Datagram: Equatable {
  public let family: IpFamily
  public let sourcePort: UInt16
  public let destinationPort: UInt16
  public let payload: Int
  public let length: Int

  public init(
    family: IpFamily, sourcePort: UInt16, destinationPort: UInt16, payload: Int, length: Int
  ) {
    self.family = family
    self.sourcePort = sourcePort
    self.destinationPort = destinationPort
    self.payload = payload
    self.length = length
  }
}
public enum UdpDecode: Equatable {
  case accepted(Datagram)
  case invalid
  case fragment
  case unsupported
}

func word(_ bytes: [UInt8], _ at: Int) -> UInt32 {
  return (UInt32(bytes[at]) << 8) | UInt32(bytes[at + 1])
}

func sumBytes(_ bytes: [UInt8], _ start: Int, _ length: Int, _ initial: UInt32) -> UInt32 {
  var sum = initial
  var index = start
  let end = start + length
  while index + 1 < end {
    sum += word(bytes, index)
    sum = (sum & 0xffff) + (sum >> 16)
    index += 2
  }
  if index < end { sum += UInt32(bytes[index]) << 8 }
  return (sum & 0xffff) + (sum >> 16)
}

public func decodeUdp(_ bytes: [UInt8]) -> UdpDecode {
  if bytes.count < 1 { return .invalid }
  let version = bytes[0] >> 4
  var family: IpFamily = .v4
  var end: Int = 0
  var start: Int = 0
  var sum: UInt32 = 0
  if version == 4 {
    if bytes.count < 20 { return .invalid }
    start = Int(bytes[0] & 15) * 4
    end = Int(word(bytes, 2))
    if start < 20 || end < start || end > bytes.count { return .invalid }
    if sumBytes(bytes, 0, start, 0) != 0xffff { return .invalid }
    let flags = word(bytes, 6)
    if (flags & 0x8000) != 0 { return .invalid }
    if (flags & 0x3fff) != 0 { return .fragment }
    if bytes[9] != 17 { return .unsupported }
    // Options must be interpreted before delivery (e.g. source routing).
    if start != 20 { return .unsupported }
    sum = sumBytes(bytes, 12, 8, 0)
  } else if version == 6 {
    if bytes.count < 40 { return .invalid }
    family = .v6
    end = 40 + Int(word(bytes, 4))
    if end > bytes.count { return .invalid }
    start = 40
    if bytes[6] == 44 { return .fragment }
    // Extension headers go through the extension-header input path.
    if bytes[6] != 17 { return .unsupported }
    sum = sumBytes(bytes, 8, 32, 0)
  } else {
    return .unsupported
  }
  if end - start < 8 { return .invalid }
  let length = Int(word(bytes, start + 4))
  if length < 8 || length != end - start { return .invalid }
  let destination = word(bytes, start + 2)
  if destination == 0 { return .invalid }
  if word(bytes, start + 6) == 0 {
    if family == .v6 { return .invalid }
  } else {
    sum += UInt32(length) + 17
    sum = (sum & 0xffff) + (sum >> 16)
    if sumBytes(bytes, start, length, sum) != 0xffff { return .invalid }
  }
  return .accepted(
    Datagram(
      family: family, sourcePort: UInt16(word(bytes, start)),
      destinationPort: UInt16(destination), payload: start + 8, length: length - 8))
}
