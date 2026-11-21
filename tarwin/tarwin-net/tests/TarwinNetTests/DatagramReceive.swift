import TarwinIPC
import TarwinObject
import TarwinSyscall
import XCTest

@testable import TarwinNet

func checkDatagram(
  caller: inout ProcessExecution, name: UInt64, denied: UInt64, port: UInt64,
  ports: inout AcceptPorts,
  object: UnsafePointer<ObjectHeader>, v6: Bool
) {
  let src: [UInt8] = v6 ? [0xfe, 0x80] + Array(repeating: 0, count: 13) + [9] : [192, 0, 2, 9]
  let dst: [UInt8] = v6 ? [0xfe, 0x80] + Array(repeating: 0, count: 13) + [2] : [192, 0, 2, 2]
  let process = caller.header.pointee.koid
  let iface: UInt32 = 0xa10f
  var binding = UdpEndpoint(process: process, family: v6 ? .v6 : .v4, port: 9, limit: 1)
  binding.peer = src
  binding.local = dst
  binding.peerPort = 0x1234
  let mailbox = UdpMailbox(
    koid: object.pointee.koid, binding: binding, interface: iface, epoch: 1, packets: 2, bytes: 6)!
  let mem = UnsafeMutableRawBufferPointer.allocate(byteCount: 41, alignment: 8)
  defer { mem.deallocate() }
  func fill() { mem.initializeMemory(as: UInt8.self, repeating: 0xce) }
  func span(_ r: Range<Int>) -> UnsafeMutableRawBufferPointer { .init(rebasing: mem[r]) }
  let peer = span(1..<33)
  let empty = span(0..<0)
  let dest = [span(34..<35), empty, span(38..<40)]
  func begin(
    _ handle: UInt64, _ flags: UInt32, _ vectors: [UnsafeMutableRawBufferPointer],
    _ address: UnsafeMutableRawBufferPointer?,
    _ call: UInt64 = TarwinCall.endpointReceiveFrom, _ allow: Bool = true
  ) -> EndpointIoStart<DatagramReceive> {
    DatagramReceive.begin(
      call: call, caller: caller, name: handle, port: port, key: 77, flags: flags, buffers: vectors,
      source: address,
      maxVectors: 3, ports: &ports, permitted: allow, resolve: { $0 == object ? mailbox : nil },
      retire: { _ in XCTFail() })
  }
  var releases = 0
  func poll(_ op: inout DatagramReceive, _ allowed: Bool = true) -> ReceiveProgress {
    op.poll(
      at: 49, ports: &ports, permitted: allowed, releasePins: { releases += 1 },
      retire: { _ in XCTFail() })
  }
  func input(_ bytes: [UInt8], _ sport: UInt16 = 0x1234, _ e: UInt64 = 1, _ allowed: Bool = true)
    -> DatagramAdmission
  {
    let route = UdpRoute(
      family: binding.family, source: src, destination: dst, sourcePort: sport, destinationPort: 9,
      hops: 64, mtu: 1500)
    guard case .packet(let ip) = udpOutput(route, bytes) else {
      XCTFail()
      return .ignored
    }
    return mailbox.input(ip + [0xcd], interface: iface, epoch: e, at: 21) { p, i, _ in
      p == process && i == iface && allowed
    }
  }
  fill()
  guard case .denied = begin(denied, 0, dest, peer),
    case .denied = begin(name, 0, dest, peer, TarwinCall.endpointReceiveFrom, false),
    case .wrongType = begin(port, 0, dest, peer), case .invalid = begin(name, 0, dest, nil),
    case .invalid = begin(name, 0, dest, span(1..<32)),
    case .invalid = begin(name, 0, dest, peer, TarwinCall.endpointReceive),
    case .invalid = begin(name, 0, dest + [empty], peer),
    case .unsupported = begin(name, 4, dest, peer),
    case .ready(var cancel) = begin(name, 0, dest, peer), case .full = begin(name, 0, dest, peer)
  else { return XCTFail() }
  XCTAssertEqual(poll(&cancel), .waiting)
  XCTAssertEqual(input([9], 0x1235), .ignored)
  XCTAssertEqual(input([9], 0x1234, 2), .ignored)
  XCTAssertEqual(input([9], 0x1234, 1, false), .denied)
  XCTAssertEqual(input([1, 2, 3, 4, 5, 6]), .queued)
  XCTAssertEqual(input([8]), .full)
  XCTAssertEqual(input([]), .queued)
  XCTAssertEqual(input([]), .full)
  XCTAssertEqual(
    ports.port.cancel(owner: OperationHandle(process: process, name: name)!) {
      XCTAssertTrue(cancel.matches(port: ports.id, operation: $0))
    }, 1)
  XCTAssertEqual(poll(&cancel), .finished)
  XCTAssertEqual(ports.port.take()?.error, 26)
  guard case .ready(var deniedRead) = begin(name, 0, dest, peer) else { return XCTFail() }
  XCTAssertEqual(poll(&deniedRead, false), .finished)
  XCTAssertEqual(ports.port.take()?.error, 4)
  XCTAssertTrue(mem.allSatisfy { $0 == 0xce })
  XCTAssertEqual(mailbox.bytesQueued, 6)
  mailbox.receiveTimestamps = true
  guard case .ready(var peek) = begin(name, 3, dest, peer) else { return XCTFail() }
  XCTAssertEqual(poll(&peek), .finished)
  let p = ports.port.take()
  XCTAssertEqual(p?.error, 0)
  XCTAssertEqual(p?.key, 77)
  XCTAssertEqual(p?.kind, 7)
  XCTAssertEqual(p?.result0, 3)
  XCTAssertEqual(p?.result1, 21)
  XCTAssertEqual(p?.aux, 1)
  var expected = [UInt8](repeating: 0, count: 32)
  expected[0] = v6 ? 1 : 0
  expected[4] = 0x34
  expected[5] = 0x12
  expected.replaceSubrange(8..<8 + src.count, with: src)
  if v6 {
    expected[6] = 1
    expected[24] = 0x0f
    expected[25] = 0xa1
  }
  XCTAssertEqual(Array(peer), expected)
  XCTAssertEqual(Array(mem[33..<41]), [0xce, 1, 0xce, 0xce, 0xce, 2, 3, 0xce])
  XCTAssertEqual(mailbox.count, 2)
  guard case .ready(var drain) = begin(name, 0, [empty], nil, TarwinCall.endpointReceive) else {
    return XCTFail()
  }
  XCTAssertEqual(poll(&drain), .finished)
  let truncated = ports.port.take()
  XCTAssertEqual(truncated?.result0, 0)
  XCTAssertEqual(truncated?.aux, 1)
  XCTAssertEqual(mailbox.bytesQueued, 0)
  XCTAssertEqual(input([7, 8]), .queued)
  mailbox.receiveTimestamps = false
  guard case .ready(var zero) = begin(name, 2, dest, nil, TarwinCall.endpointReceive) else {
    return XCTFail()
  }
  XCTAssertEqual(poll(&zero), .finished)
  let z = ports.port.take()
  XCTAssertEqual(z?.result0, 0)
  XCTAssertEqual(z?.result1, 0)
  XCTAssertEqual(z?.aux, 0)
  guard case .ready(var short) = begin(name, 2, dest, nil, TarwinCall.endpointReceive) else {
    return XCTFail()
  }
  XCTAssertEqual(poll(&short), .finished)
  let s = ports.port.take()
  XCTAssertEqual(s?.result0, 2)
  XCTAssertEqual(s?.aux, 0)
  XCTAssertEqual(mailbox.count, 0)
  checkBatch(
    caller: &caller, name: name, port: port, ports: &ports, object: object, mailbox: mailbox,
    expectedPeer: expected,
    makePacket: { payload in
      udpOutput(
        UdpRoute(
          family: binding.family, source: src, destination: dst, sourcePort: binding.peerPort,
          destinationPort: 9, hops: 64, mtu: 1500), payload)
    })
  fill()
  guard case .ready(var pending) = begin(name, 0, dest, peer) else { return XCTFail() }
  mailbox.close()
  XCTAssertEqual(poll(&pending), .finished)
  XCTAssertEqual(ports.port.take()?.error, 23)
  XCTAssertTrue(mem.allSatisfy { $0 == 0xce })
  XCTAssertEqual(input([1]), .ignored)
  XCTAssertEqual(ports.refs, 0)
  XCTAssertEqual(releases, 7)
}
