/// A userspace NetAddress is copied once, before the caller may reuse it.
public struct DatagramPeer: Equatable {
  public let address: [UInt8], port: UInt16, scope: UInt32
  public init?(address: [UInt8], port: UInt16, scope: UInt32 = 0) {
    guard port != 0, address.count == 16 || (address.count == 4 && scope == 0) else { return nil }
    self.address = address
    self.port = port
    self.scope = scope
  }
  public init?(record: UnsafeRawBufferPointer) {
    guard record.count == 32, record.baseAddress != nil, record[0] <= 1,
      record[1..<4].allSatisfy({ $0 == 0 }), record[6] <= 1, record[7] == 0,
      record[28..<32].allSatisfy({ $0 == 0 }),
      record[0] == 1 || record[12..<24].allSatisfy({ $0 == 0 })
    else { return nil }
    var scope: UInt32 = 0
    for i in 0..<4 { scope |= UInt32(record[24 + i]) << (i * 8) }
    guard (scope != 0) == (record[6] != 0) else { return nil }
    self.init(
      address: Array(record[8..<(record[0] == 0 ? 12 : 24)]),
      port: UInt16(record[4]) | UInt16(record[5]) << 8, scope: scope)
  }
}
public enum DatagramPublish { case empty, blocked, denied, published }
struct DatagramEgress {
  struct Packet { let route: UdpRoute, ip: [UInt8] }
  let byteLimit: Int
  private var storage: [Packet?], head = 0
  private(set) var count = 0, bytes = 0
  var room: Int { storage.count - count }
  var next: Packet? { storage[head] }
  init(packets: Int, bytes: Int) {
    storage = .init(repeating: nil, count: packets)
    byteLimit = bytes
  }
  mutating func append(_ packet: Packet) {
    precondition(room > 0 && packet.ip.count <= byteLimit - bytes)
    storage[(head + count) % storage.count] = packet
    count += 1
    bytes += packet.ip.count
  }
  mutating func remove() {
    bytes -= storage[head]!.ip.count
    storage[head] = nil
    head = (head + 1) % storage.count
    count -= 1
  }
  mutating func clear() { while count > 0 { remove() } }
}
extension UdpMailbox {
  /// Under the endpoint's worker lock. Pacing / neighbor resolution belongs
  /// to publish. It takes ownership only on success. Never reroute stale TX.
  public func publish(
    interface: UInt32, epoch: UInt64, permit: (UInt64, UdpRoute) -> Bool,
    send: (UdpRoute, [UInt8]) -> Bool
  ) -> DatagramPublish {
    guard !closed, let packet = egress.next else { return .empty }
    guard interface == self.interface, epoch == self.epoch else { return .denied }
    guard permit(binding.process, packet.route) else {
      egress.remove()
      return .denied
    }
    guard send(packet.route, packet.ip) else { return .blocked }
    egress.remove()
    return .published
  }
}
