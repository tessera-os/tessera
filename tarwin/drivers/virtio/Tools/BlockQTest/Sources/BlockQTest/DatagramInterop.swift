import TarwinNet
import TarwinObject
import TarwinSyscall

func sendDatagram(route: UdpRoute, payload: [UInt8]) throws -> [UInt8] {
  var packet: [UInt8] = []
  try withTestEndpoint { caller, _, object, _, name, port, ports in
    let owner = caller.header.pointee.koid
    var binding = UdpEndpoint(
      process: owner, family: route.family, port: route.sourcePort, limit: 1)
    binding.local = route.source
    guard let peer = DatagramPeer(address: route.destination, port: route.destinationPort),
      let out = UdpMailbox(
        koid: object.pointee.koid, binding: binding, interface: 3, epoch: 1, packets: 1, bytes: 1500
      )
    else { throw Failure("Bad sendTo binding") }
    try payload.withUnsafeBytes { buf in
      let cut = buf.count / 2
      guard
        case .ready(var op) = DatagramSend.begin(
          call: TarwinCall.endpointSendTo, caller: caller, name: name, port: port,
          key: 21, flags: 0, sources: [.init(rebasing: buf[..<cut]), .init(rebasing: buf[cut...])],
          peer: peer,
          maxVectors: 2, ports: &ports, permitted: true, resolve: { $0 == object ? out : nil },
          retire: { _ in preconditionFailure() })
      else { throw Failure("Cannot submit sendTo") }
      var pins = 1
      defer {
        _ = op.withdraw(
          at: 1, ports: &ports, releasePins: { pins -= 1 }, retire: { _ in preconditionFailure() })
      }
      guard
        op.poll(
          at: 0, ports: &ports, permitted: true,
          route: { p, i, e, d in
            p == owner && i == 3 && e == 1 && d == peer ? .route(route) : .denied
          }, releasePins: { pins -= 1 }, retire: { _ in preconditionFailure() }) == .finished,
        let result = ports.port.take(), result.error == 0, result.key == 21, result.kind == 7,
        result.result0 == UInt64(buf.count), pins == 0, ports.references == 0
      else { throw Failure("sendTo completion mismatch") }
    }
    guard
      out.publish(
        interface: 3, epoch: 1, permit: { p, r in p == owner && r == route },
        send: { _, ip in
          packet = ip
          return true
        }) == .published
    else { throw Failure("No staged datagram for NIC") }
  }
  return packet
}

func checkDatagramEndpoint(_ ip: [UInt8], route: UdpRoute, expected: [UInt8]) throws {
  try withTestEndpoint { caller, _, object, _, name, port, ports in
    let owner = caller.header.pointee.koid
    var binding = UdpEndpoint(
      process: owner, family: route.family, port: route.destinationPort, limit: 1)
    binding.local = route.destination
    binding.peer = route.source
    binding.peerPort = route.sourcePort
    guard
      let inbox = UdpMailbox(
        koid: object.pointee.koid, binding: binding, interface: 3, epoch: 1, packets: 1, bytes: 1500
      )
    else { throw Failure("Bad datagram binding") }
    let buffer = UnsafeMutableRawBufferPointer.allocate(
      byteCount: expected.count + 35, alignment: 8)
    defer { buffer.deallocate() }
    buffer.initializeMemory(as: UInt8.self, repeating: 0xbd)
    let source = UnsafeMutableRawBufferPointer(rebasing: buffer[1..<33])
    let cut = expected.count / 2
    let a = UnsafeMutableRawBufferPointer(rebasing: buffer[34..<34 + cut])
    let b = UnsafeMutableRawBufferPointer(rebasing: buffer[(35 + cut)...])
    guard
      case .ready(var op) = DatagramReceive.begin(
        call: TarwinCall.endpointReceiveFrom, caller: caller,
        name: name, port: port, key: 107, flags: 0, buffers: [a, b], source: source, maxVectors: 2,
        ports: &ports, permitted: true,
        resolve: { $0 == object ? inbox : nil }, retire: { _ in preconditionFailure() })
    else { throw Failure("Cannot submit UDP receiveFrom") }
    var released = 0
    defer {
      _ = op.withdraw(
        at: 4, ports: &ports, releasePins: { released += 1 }, retire: { _ in preconditionFailure() }
      )
    }
    guard
      op.poll(
        at: 1, ports: &ports, permitted: true, releasePins: { released += 1 },
        retire: { _ in preconditionFailure() }) == .waiting,
      inbox.input(ip, interface: 3, epoch: 1, at: 2, permit: { p, i, _ in p == owner && i == 3 })
        == .queued,
      op.poll(
        at: 3, ports: &ports, permitted: true, releasePins: { released += 1 },
        retire: { _ in preconditionFailure() }) == .finished,
      let packet = ports.port.take(), packet.kind == 7, packet.error == 0, packet.key == 107,
      packet.aux == 0,
      packet.result0 == UInt64(expected.count), released == 1, ports.references == 0,
      inbox.count == 0,
      source[0] == (route.family == .v6 ? 1 : 0),
      Array(source[8..<8 + route.source.count]) == route.source,
      UInt16(source[4]) | UInt16(source[5]) << 8 == route.sourcePort,
      buffer[0] == 0xbd, buffer[33] == 0xbd, buffer[34 + cut] == 0xbd, Array(a) + b == expected
    else { throw Failure("UDP source, scatter result or Net completion differed") }
  }
}
