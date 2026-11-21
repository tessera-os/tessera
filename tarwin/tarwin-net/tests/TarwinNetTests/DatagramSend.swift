import TarwinIPC
import TarwinObject
import TarwinSyscall
import XCTest

@testable import TarwinNet

func checkDatagramSend(
  caller: inout ProcessExecution, name: UInt64, denied: UInt64, port: UInt64,
  ports: inout AcceptPorts,
  object: UnsafePointer<ObjectHeader>, v6: Bool
) {
  let local: [UInt8] = v6 ? [0xfe, 0x80] + Array(repeating: 0, count: 13) + [3] : [192, 0, 2, 3]
  let remote: [UInt8] = v6 ? [0xfe, 0x80] + Array(repeating: 0, count: 13) + [4] : [192, 0, 2, 4]
  let peer = DatagramPeer(address: remote, port: 1234, scope: v6 ? 5 : 0)!
  let owner = caller.header.pointee.koid
  var binding = UdpEndpoint(process: owner, family: v6 ? .v6 : .v4, port: 5678, limit: 1)
  binding.local = local
  binding.peer = remote
  binding.peerPort = 1234
  let box = UdpMailbox(
    koid: object.pointee.koid, binding: binding, interface: 5, epoch: 3, packets: 2, bytes: 3000)!
  let rows = UnsafeMutableRawBufferPointer.allocate(byteCount: 56 * 3, alignment: 8)
  let bytes = UnsafeMutableRawBufferPointer.allocate(byteCount: 6, alignment: 8)
  defer {
    rows.deallocate()
    bytes.deallocate()
  }
  for i in bytes.indices { bytes[i] = UInt8(i) }
  let spans = [
    UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(bytes)[1..<3]),
    UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(bytes)[4..<6]),
  ]
  let empty = UnsafeRawBufferPointer(start: nil, count: 0)
  func begin(
    _ h: UInt64, _ flags: UInt32, _ addr: DatagramPeer?, _ call: UInt64 = TarwinCall.endpointSendTo
  ) -> EndpointIoStart<DatagramSend> {
    DatagramSend.begin(
      call: call, caller: caller, name: h, port: port, key: 12, flags: flags, sources: spans,
      peer: addr, maxVectors: 2, ports: &ports, permitted: true,
      resolve: { $0 == object ? box : nil }, retire: { _ in XCTFail() })
  }
  func many(_ maxVectors: Int = 4) -> EndpointIoStart<DatagramSend> {
    DatagramSend.beginMany(
      call: TarwinCall.endpointSendMany, caller: caller, name: name, port: port, key: 77, flags: 0,
      sources: [spans, [empty], [empty]], records: rows, maxMessages: 3, maxVectors: maxVectors,
      ports: &ports, permitted: true,
      resolve: { $0 == object ? box : nil }, retire: { _ in XCTFail() })
  }
  var released = 0
  func poll(_ op: inout DatagramSend, _ authorized: Bool = true, _ routeError: UInt32 = 0)
    -> SendProgress
  {
    op.poll(
      at: 5, ports: &ports, permitted: authorized,
      route: { p, i, e, d in
        XCTAssertEqual(p, owner)
        XCTAssertEqual(i, 5)
        XCTAssertEqual(e, 3)
        if routeError == 4 { return .denied }
        if routeError == 62 { return .unreachable }
        return .route(
          UdpRoute(
            family: binding.family, source: local, destination: d.address,
            sourcePort: routeError == 64 ? 2 : binding.port,
            destinationPort: d.port, hops: 64, mtu: routeError == 6 ? 24 : 1500))
      }, releasePins: { released += 1 }, retire: { _ in XCTFail() })
  }
  func fill() {
    rows.initializeMemory(as: UInt8.self, repeating: 0xba)
    for i in 0..<3 {
      storePeer(
        remote, port: 1234 + UInt16(i), interface: 5,
        to: .init(rebasing: rows[(i * 56 + 16)..<(i * 56 + 48)]))
    }
  }
  func publish(_ dst: UInt16, _ expected: [UInt8]) {
    XCTAssertEqual(
      box.publish(
        interface: 5, epoch: 3, permit: { p, r in p == owner && r.destinationPort == dst },
        send: { r, ip in
          guard case .accepted(let d) = decodeUdp(ip) else {
            XCTFail()
            return false
          }
          XCTAssertEqual(d.destinationPort, dst)
          XCTAssertEqual(d.sourcePort, 5678)
          XCTAssertEqual(r.destination, remote)
          XCTAssertEqual(Array(ip[d.payload..<d.payload + d.length]), expected)
          return true
        }), .published)
  }
  guard case .denied = begin(denied, 0, peer), case .invalid = begin(name, 0, nil),
    case .unsupported = begin(name, 2, peer),
    case .invalid = begin(name, 0, peer, TarwinCall.endpointSend),
    case .ready(var connected) = begin(name, 1, nil, TarwinCall.endpointSend)
  else { return XCTFail() }
  XCTAssertEqual(poll(&connected), .finished)
  XCTAssertEqual(ports.port.take()?.result0, 4)
  bytes[1] = 99
  XCTAssertEqual(
    box.publish(
      interface: 5, epoch: 4, permit: { _, _ in true },
      send: { _, _ in
        XCTFail()
        return true
      }), .denied)
  XCTAssertEqual(
    box.publish(interface: 5, epoch: 3, permit: { _, _ in true }, send: { _, _ in false }), .blocked
  )
  publish(1234, [1, 2, 4, 5])
  for code: UInt32 in [4, 6, 62, 64] {
    guard case .ready(var wrong) = begin(name, 0, peer) else { return XCTFail() }
    XCTAssertEqual(poll(&wrong, true, code), .finished)
    XCTAssertEqual(ports.port.take()?.error, code)
  }
  fill()
  guard case .invalid = many(3) else { return XCTFail() }
  rows[44] = 1
  guard case .invalid = many() else { return XCTFail() }
  fill()
  guard case .ready(var cancel) = many() else { return XCTFail() }
  let snapshot = Array(rows)
  let id = ports.id
  XCTAssertEqual(
    ports.port.cancel(owner: OperationHandle(process: owner, name: name)!) {
      XCTAssertTrue(cancel.matches(port: id, operation: $0))
    }, 1)
  XCTAssertEqual(poll(&cancel), .finished)
  XCTAssertEqual(ports.port.take()?.error, 26)
  XCTAssertEqual(Array(rows), snapshot)
  XCTAssertEqual(box.egress.count, 0)
  guard case .ready(var batch) = many() else { return XCTFail() }
  rows[20] = 0  // Destination scalars were snapshotted at submission.
  XCTAssertEqual(poll(&batch), .finished)
  let completion = ports.port.take()
  XCTAssertEqual(completion?.result0, 2)
  XCTAssertEqual(completion?.key, 77)
  XCTAssertEqual(completion?.error, 0)
  var result = snapshot
  result[20] = 0
  for i in 0..<2 {
    result.replaceSubrange((56 * i + 12)..<(56 * i + 16), with: [0, 0, 0, 0])
    result.replaceSubrange(
      (56 * i + 48)..<(56 * i + 56), with: [i == 0 ? 4 : 0, 0, 0, 0, 0, 0, 0, 0])
  }
  XCTAssertEqual(Array(rows), result)
  guard case .ready(var pending) = begin(name, 0, peer) else { return XCTFail() }
  XCTAssertEqual(poll(&pending), .waiting)
  publish(1234, [99, 2, 4, 5])
  XCTAssertEqual(poll(&pending), .finished)
  XCTAssertEqual(ports.port.take()?.result0, 4)
  publish(1235, [])
  XCTAssertEqual(
    box.publish(
      interface: 5, epoch: 3, permit: { _, _ in false },
      send: { _, _ in
        XCTFail()
        return false
      }), .denied)
  XCTAssertEqual(box.egress.count, 0)
  guard case .ready(var dead) = begin(name, 0, peer) else { return XCTFail() }
  box.close()
  XCTAssertEqual(poll(&dead), .finished)
  XCTAssertEqual(ports.port.take()?.error, 23)
  XCTAssertEqual(box.egress.bytes, 0)
  XCTAssertEqual(ports.refs, 0)
  XCTAssertEqual(released, 9)
}
