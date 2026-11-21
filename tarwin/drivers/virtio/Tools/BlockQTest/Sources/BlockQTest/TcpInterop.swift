import Darwin
import Foundation
import TarwinNet

/// ISS and routing policy are private test inputs; the kernel TCP package
/// produces every TCP segment on this side of the isolated link.
func tcpInterop(
  mac: [UInt8], input: FileHandle, output: FileHandle, post: () throws -> Void,
  send: ([UInt8]) throws -> Void,
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
  let path = TcpPath(
    local: local, remote: peer, localPort: localPort, remotePort: service, mtu: 1500)!
  let offset: UInt32 = 0xb001_0001
  var c = TcpConnection(
    path: path, initialSequence: initial, receiveBytes: 131_070,
    timestampOffset: offset)!
  var peerTS: UInt32?
  var peerScale: UInt8?
  var now: UInt64 = 0
  var failure: Error?
  func emit(_ ip: [UInt8]) -> Bool {
    do {
      guard let p = tcpSegment(ip) else { throw Failure("Invalid outgoing TCP packet") }
      if p.flags == 2 {
        guard p.options.timestamp == offset, p.options.scale == 1, p.window == 65535 else {
          throw Failure("Invalid TCP SYN options")
        }
      } else {
        guard (p.options.timestamp != nil) == (peerTS != nil), p.options.scale == nil else {
          throw Failure("TCP option negotiation mismatch")
        }
      }
      try send(dst + mac + [8, 0] + ip)
      return true
    } catch {
      failure = error
      return false
    }
  }
  func ingest() throws {
    for i in 0..<6 {
      let b = try take()
      if b.count >= 54, b.prefix(6).elementsEqual(mac),
        b[6..<12].elementsEqual(dst) || b[6..<12].elementsEqual(gateway), b[12] == 8, b[13] == 0,
        let p = tcpSegment(Array(b.dropFirst(14))), c.input(p, at: now, admit: { _ in true })
      {
        if p.flags & 0x12 == 0x12 {
          peerTS = p.options.timestamp
          peerScale = p.options.scale
        }
        return
      }
      if i != 5 { try post() }
    }
    throw Failure("No admitted guestfwd segment")
  }
  func pump() throws {
    _ = c.pump(at: now, emit: emit)
    if let failure { throw failure }
  }
  try post()
  guard c.connect(at: now, emit: emit) else { throw failure ?? Failure("Active open failed") }
  now += 1
  try ingest()
  guard c.state == .established else { throw Failure("No valid SYN-ACK") }
  try pump()
  for chunk in [Array("first".utf8), [0, 255, 13, 10], Array("third chunk".utf8)] {
    try post()
    try input.write(contentsOf: Data(chunk))
    var copied: [UInt8] = []
    for i in 0..<8 {
      now += 1
      try ingest()
      _ = c.read(upTo: 64) {
        copied += Array($0)
        return true
      }
      try pump()
      if copied.count >= chunk.count { break }
      if i != 7 { try post() }
    }
    guard copied == chunk else { throw Failure("TCP input differs from pipe") }
  }
  let reply: [UInt8] = [0xca, 0xfe, 0, 1, 2, 255]
  var lost: [UInt8] = []
  // Drop the first published datagram at the test link, not in the TCP sender.
  guard
    c.write(
      reply[...], at: now,
      emit: {
        lost = $0
        return true
      }) == reply.count,
    let sent = tcpSegment(lost), Array(sent.payload) == reply
  else { throw Failure("No initial TCP output") }
  try post()
  now += 2_000_000_000
  guard
    c.pump(
      at: now,
      emit: { ip in
        guard let retry = tcpSegment(ip), retry.sequence == sent.sequence, retry.ack == sent.ack,
          retry.flags == sent.flags, retry.payload.elementsEqual(sent.payload),
          retry.options.timestamp == sent.options.timestamp.map({ $0 &+ 2000 })
        else { return false }
        return emit(ip)
      })
  else {
    throw failure ?? Failure("Missing timer retransmission")
  }
  now += 1
  try ingest()
  guard c.unacknowledged == 0 else { throw Failure("Peer did not acknowledge retransmission") }
  var fd = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
  var received = [UInt8](repeating: 0, count: reply.count + 1)
  guard Darwin.poll(&fd, 1, 2000) > 0,
    received.withUnsafeMutableBytes({ Darwin.read(fd.fd, $0.baseAddress, $0.count) })
      == reply.count,
    received.prefix(reply.count).elementsEqual(reply)
  else { throw Failure("Peer did not deliver exact TCP output") }
  try post()
  guard c.finish(at: now, emit: emit) else { throw Failure("Could not half close") }
  for i in 0..<4 {
    now += 1
    try ingest()
    try pump()
    if c.unacknowledged == 0 { break }
    if i != 3 { try post() }
  }
  guard c.unacknowledged == 0, c.state == .finWait2 || c.state == .timeWait else {
    throw Failure("Peer did not ACK FIN")
  }
  print(
    "Peer SYN-ACK: timestamps \(peerTS == nil ? "declined" : "accepted"), window scale \(peerScale.map(String.init) ?? "declined")"
  )
}
