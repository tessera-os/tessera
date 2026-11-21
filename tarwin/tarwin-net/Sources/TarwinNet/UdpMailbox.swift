public enum DatagramAdmission { case ignored, denied, full, queued }

struct UdpMessage {
  let bytes: [UInt8], source: [UInt8], sourcePort: UInt16, receivedAt: UInt64
}

/// The network worker serializes admission, reads and revocation. The object
/// is bound to one authorized interface generation, not just an address.
public final class UdpMailbox: EndpointPayload {
  public let koid: UInt64, epoch: UInt64, interface: UInt32
  let binding: UdpEndpoint
  private let byteLimit: Int
  var egress: DatagramEgress
  public var receiveTimestamps = false
  public private(set) var closed = false, count = 0, bytesQueued = 0
  private var slots: [UdpMessage?], head = 0
  public init?(
    koid: UInt64, binding: UdpEndpoint, interface: UInt32, epoch: UInt64, packets: Int, bytes: Int
  ) {
    let width = binding.family == .v4 ? 4 : 16
    guard koid != 0, binding.process != 0, binding.port != 0, !binding.closed,
      binding.receives.isEmpty,
      binding.local.isEmpty || binding.local.count == width,
      binding.peer.isEmpty || binding.peer.count == width,
      interface != 0, binding.interfaceId == 0 || binding.interfaceId == UInt64(interface),
      epoch != 0, (1...4096).contains(packets), (0...16 * 1024 * 1024).contains(bytes)
    else { return nil }
    self.koid = koid
    self.binding = binding
    self.interface = interface
    self.epoch = epoch
    byteLimit = bytes
    egress = DatagramEgress(packets: packets, bytes: bytes)
    slots = .init(repeating: nil, count: packets)
  }
  func acceptsIo(object: UInt64) -> Bool { object == koid && !closed }
  func message(at offset: Int) -> UdpMessage {
    precondition(offset >= 0 && offset < count)
    return slots[(head + offset) % slots.count]!
  }
  func dequeue() {
    precondition(count > 0)
    bytesQueued -= slots[head]!.bytes.count
    slots[head] = nil
    head = (head + 1) % slots.count
    count -= 1
  }
  public func close() {
    closed = true
    while count != 0 { dequeue() }
    egress.clear()
  }
  /// Admit only whole, validated messages; a zero-length payload still costs
  /// one queue slot. Never retain padding or the input driver's frame storage.
  public func input(
    _ ip: [UInt8], interface: UInt32, epoch: UInt64, at now: UInt64,
    permit: (UInt64, UInt32, [UInt8]) -> Bool
  ) -> DatagramAdmission {
    guard !closed, self.interface == interface, self.epoch == epoch,
      case .accepted(let d) = decodeUdp(ip), binding.matches(d, ip, UInt64(interface))
    else { return .ignored }
    guard permit(binding.process, interface, ip) else { return .denied }
    guard count < slots.count, d.length <= byteLimit - bytesQueued else { return .full }
    let source = d.family == .v4 ? 12..<16 : 8..<24
    slots[(head + count) % slots.count] = UdpMessage(
      bytes: Array(ip[d.payload..<d.payload + d.length]),
      source: Array(ip[source]), sourcePort: d.sourcePort, receivedAt: now)
    bytesQueued += d.length
    count += 1
    return .queued
  }
}
