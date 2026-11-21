import Darwin
import Foundation
import TarwinNet

func passiveInterop(
  mac: [UInt8], socketPath: String, post: () throws -> Void, send: ([UInt8]) throws -> Void,
  take: () throws -> [UInt8]
) throws {
  let local: [UInt8] = [10, 0, 2, 15]
  let service: UInt16 = 4242
  let link = NeighborInterface(mac: mac, address: local)!
  var l = TcpListener(
    serverEntitled: true, local: local, port: service, interface: 7, epoch: 1, backlog: 2,
    receiveBytes: 2048)!
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { throw Failure("Cannot open private peer socket") }
  defer { close(fd) }
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let path = Array(socketPath.utf8CString)
  guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
    throw Failure("Unix socket path too long")
  }
  withUnsafeMutableBytes(of: &address.sun_path) {
    $0.copyBytes(from: path.map { UInt8(bitPattern: $0) })
  }
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  let len = socklen_t(address.sun_len)
  try post()
  let connected = withUnsafePointer(to: &address) { p in
    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
  }
  guard connected == 0 else {
    throw Failure("Private peer connect: \(String(cString:strerror(errno)))")
  }
  let request: [UInt8] = [234, 0, 255, 8, 13, 10]
  let response: [UInt8] = [7, 0, 255, 4]
  guard request.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress, $0.count) }) == request.count
  else {
    throw Failure("Private peer write failed")
  }
  var now: UInt64 = 0
  var dst: [UInt8] = []
  var txError: Error?
  func emit(_ packet: [UInt8]) -> Bool {
    do {
      try send(dst + mac + [8, 0] + packet)
      return true
    } catch {
      txError = error
      return false
    }
  }
  func next() throws -> TcpSegment {
    for _ in 0..<8 {
      let b = try take()
      try post()
      if let arp = link.reply(b) {
        try send(arp)
        continue
      }
      guard b.count >= 54, b.prefix(6).elementsEqual(mac), b[12] == 8, b[13] == 0,
        let p = tcpSegment(Array(b.dropFirst(14))), p.destination == local,
        p.destinationPort == service
      else { continue }
      dst = Array(b[6..<12])
      now += 1
      return p
    }
    throw Failure("No matching inbound TCP segment")
  }
  for _ in 0..<8 {
    let p = try next()
    guard
      let route = TcpPath(
        local: local, remote: p.source, localPort: service, remotePort: p.sourcePort, mtu: 1500)
    else { throw Failure("Bad passive route") }
    let result = l.input(
      p, path: route, interface: 7, epoch: 1, at: now, permit: { _ in true },
      initial: { (0x1003, 0x7000) }, canPromote: { true }, emit: { _, b in emit(b) })
    if let txError { throw txError }
    guard case .established(var c) = result else { continue }
    var received: [UInt8] = []
    for _ in 0..<8 {
      _ = c.read(upTo: request.count) {
        received += Array($0)
        return true
      }
      _ = c.pump(at: now, emit: emit)
      if let txError { throw txError }
      if received.count >= request.count { break }
      let segment = try next()
      guard c.input(segment, at: now, admit: { _ in true }) else {
        throw Failure("Rejected peer data")
      }
    }
    guard received == request, c.write(response[...], at: now, emit: emit) == response.count else {
      throw txError ?? Failure("Passive stream data mismatch")
    }
    var got: [UInt8] = []
    while got.count < response.count {
      var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      guard poll(&poller, 1, 3000) > 0 else { throw Failure("Private peer timed out") }
      var buf = [UInt8](repeating: 0, count: response.count - got.count)
      let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
      guard n > 0 else { throw Failure("Private peer read failed") }
      got += buf.prefix(n)
    }
    guard got == response else { throw Failure("Private peer bytes differ") }
    return
  }
  throw Failure("Passive handshake did not complete")
}
