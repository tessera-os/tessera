// Modern virtio-net, 12-byte header, independent queue pairs. This path implements
// completed TX checksums; do not advertise GSO, UFO, mergeable RX or hash reports.
public struct NetPolicy {
  public let mtu: UInt64
  public let checksum: Bool
  public let bridge: Bool
  public let hypervisorResource: Bool

  public init(mtu: UInt64, checksum: Bool, bridge: Bool, hypervisorResource: Bool) {
    self.mtu = mtu
    self.checksum = checksum
    self.bridge = bridge
    self.hypervisorResource = hypervisorResource
  }
}
func validFrame(_ size: UInt64, _ p: NetPolicy) -> Bool {
  return (!p.bridge || p.hypervisorResource) && p.mtu >= 68 && p.mtu <= 65535
    && size >= 14 && size <= p.mtu + 18
}

// The checksum field carries the guest's partial pseudo-header sum. Complete a
// network-order one's-complement checksum, padding an odd final octet with zero.
public func netTransmit(
  _ command: [UInt8], _ policy: NetPolicy,
  _ send: ([UInt8]) -> Bool
) -> Bool {
  if command.count < 26 || !validFrame(UInt64(command.count - 12), policy) { return false }
  let flags = command[0]
  if flags > 1 || (flags == 1 && !policy.checksum) || command[1] != 0 { return false }
  var frame: [UInt8] = []
  for i in 12..<command.count { frame.append(command[i]) }
  if flags == 1 {
    let start = Int(vword(command, 6, 2))
    let at = start + Int(vword(command, 8, 2))
    if at > frame.count - 2 { return false }
    var sum: UInt64 = 0
    for i in start..<frame.count {
      sum += ((i - start) % 2 == 0) ? UInt64(frame[i]) << 8 : UInt64(frame[i])
    }
    while sum > 65535 { sum = (sum & 65535) + (sum >> 16) }
    let value = sum ^ 65535
    frame[at] = UInt8(value >> 8)
    frame[at + 1] = UInt8(value & 255)
  }
  return send(frame)
}

public func netReceive(_ frame: [UInt8], _ space: UInt64, _ policy: NetPolicy) -> [UInt8]? {
  if !validFrame(UInt64(frame.count), policy) || space < UInt64(frame.count) + 12 { return .none }
  var data: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0]
  for b in frame { data.append(b) }
  return .some(data)
}
