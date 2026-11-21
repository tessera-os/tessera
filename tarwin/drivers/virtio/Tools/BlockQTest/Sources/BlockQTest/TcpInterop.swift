import Foundation
import TarwinNet

/// Only the receive half is under test. This fixed fixture supplies an
/// active-open SYN and ACK-only output, never a production sender or ISS.
func tcpReceiveInterop(
  mac: [UInt8], pipe: FileHandle, post: () throws -> Void, send: ([UInt8]) throws -> Void,
  take: () throws -> [UInt8]
) throws {
  let local: [UInt8] = [10, 0, 2, 15]
  let peer: [UInt8] = [10, 0, 2, 100]
  let localPort: UInt16 = 32001
  let service: UInt16 = 4242
  let initial: UInt32 = 0x1ab1_0000
  func resolve(_ address: [UInt8]) throws -> [UInt8] {
    guard let link = NeighborInterface(mac: mac, address: local),
      var table = NeighborTable(interface: link, limit: 1, retryNs: 100, reachableNs: 1000),
      case .send(let query) = table.resolve(address, now: 0)
    else { throw Failure("Cannot resolve fixture peer") }
    try post()
    try send(query)
    for i in 0..<4 {
      if table.confirm(try take(), now: 1) { break }
      if i != 3 { try post() }
    }
    guard case .resolved(let result) = table.resolve(address, now: 2) else {
      throw Failure("Missing fixture ARP reply")
    }
    return result
  }
  let dst = try resolve(peer)
  let gateway = try resolve([10, 0, 2, 2])
  func be(_ x: UInt32, _ n: Int) -> [UInt8] {
    (0..<n).reversed().map { UInt8(truncatingIfNeeded: x >> ($0 * 8)) }
  }
  func sum(_ b: [UInt8]) -> [UInt8] {
    var s = 0
    for (i, v) in b.enumerated() { s += Int(v) << (i % 2 == 0 ? 8 : 0) }
    while s > 65535 { s = (s & 65535) + (s >> 16) }
    return be(UInt32(65535 - s), 2)
  }
  func control(syn: Bool, ack: UInt32, window: UInt32) throws {
    let seq = syn ? initial : initial + 1
    var tcp =
      be(UInt32(localPort), 2) + be(UInt32(service), 2) + be(seq, 4) + be(ack, 4) + [
        0x50, syn ? 2 : 16,
      ] + be(window, 2) + [0, 0, 0, 0]
    tcp.replaceSubrange(16..<18, with: sum(local + peer + [0, 6, 0, 20] + tcp))
    var ip: [UInt8] = [0x45, 0, 0, 40, 0, 1, 0x40, 0, 64, 6, 0, 0] + local + peer
    ip.replaceSubrange(10..<12, with: sum(ip))
    try send(dst + mac + [8, 0] + ip + tcp)
  }
  func fromPeer(_ s: TcpSegment) -> Bool {
    s.family == .v4 && s.source == peer && s.destination == local && s.sourcePort == service
      && s.destinationPort == localPort && s.ack == initial + 1
  }
  func receive(_ match: (TcpSegment) -> Bool) throws -> TcpSegment {
    for n in 0..<6 {
      let b = try take()
      if b.count >= 54, b.prefix(6).elementsEqual(mac),
        b[6..<12].elementsEqual(dst) || b[6..<12].elementsEqual(gateway), b[12] == 8,
        b[13] == 0,
        let s = tcpSegment(Array(b.dropFirst(14))), fromPeer(s), match(s)
      {
        return s
      }
      if n != 5 { try post() }
    }
    throw Failure("No matching TCP response")
  }
  try post()
  try control(syn: true, ack: 0, window: 64)
  let opened = try receive { $0.flags & 0x17 == 0x12 }
  var rx = TcpReceiveWindow(next: opened.sequence &+ 1, capacity: 64, sackNegotiated: false)!
  try control(syn: false, ack: rx.acknowledgement.next, window: rx.acknowledgement.window)
  for chunk in [Array("first".utf8), [0, 255, 13, 10], Array("third chunk".utf8)] {
    try post()
    try pipe.write(contentsOf: Data(chunk))
    var copied: [UInt8] = []
    while copied.count < chunk.count {
      let s = try receive { !$0.payload.isEmpty }
      guard rx.receive(s, admit: fromPeer) else { throw Failure("TCP input refused") }
      _ = rx.read(upTo: 64) {
        copied += Array($0)
        return true
      }
      try control(syn: false, ack: rx.acknowledgement.next, window: rx.acknowledgement.window)
      if copied.count < chunk.count { try post() }
    }
    guard copied == chunk else { throw Failure("TCP stream did not match private pipe") }
  }
}
