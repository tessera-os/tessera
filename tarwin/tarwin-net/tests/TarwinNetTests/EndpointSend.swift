import TarwinIPC
import TarwinObject
import TarwinSyscall
import XCTest

@testable import TarwinNet

func checkSend(
  caller: inout ProcessExecution, name: UInt64, denied: UInt64, port: UInt64,
  ports: inout AcceptPorts, child: UnsafePointer<ObjectHeader>, stream: TcpAcceptedStream,
  incoming: TcpPath
) {
  let mem = UnsafeMutableRawBufferPointer.allocate(byteCount: 2000, alignment: 8)
  defer { mem.deallocate() }
  mem.initializeMemory(as: UInt8.self, repeating: 0xfe)
  mem[3] = 7
  mem[4] = 0
  mem[7] = 255
  let first = UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(mem)[3..<5])
  let last = UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(mem)[7..<8])
  let empty = UnsafeRawBufferPointer(start: nil, count: 0)
  let vectors = [first, empty, last]
  func begin(_ h: UInt64, _ flags: UInt32, _ b: [UnsafeRawBufferPointer]) -> SendStart {
    EndpointSend.begin(
      call: TarwinCall.endpointSend, caller: caller, name: h, port: port, key: 49, flags: flags,
      sources: b,
      maxVectors: 3, ports: &ports, permitted: true, resolve: { $0 == child ? stream : nil },
      retire: { _ in XCTFail() })
  }
  guard case .denied = begin(denied, 0, vectors), case .unsupported = begin(name, 4, vectors),
    case .wrongType = begin(port, 0, vectors), case .invalid = begin(name, 0, vectors + [empty])
  else { return XCTFail() }
  var freed = 0
  func poll(_ s: inout EndpointSend, _ allowed: Bool) -> SendProgress {
    s.poll(
      at: 10, ports: &ports, permitted: allowed, releasePins: { freed += 1 },
      retire: { _ in XCTFail() })
  }
  func pump(_ at: UInt64, _ ok: Bool) -> [UInt8]? {
    var output: [UInt8]?
    _ = stream.connection.pump(at: at) {
      output = tcpSegment($0).map { Array($0.payload) }
      return ok
    }
    return output
  }
  guard case .ready(var rejected) = begin(name, 0, vectors), case .full = begin(name, 0, vectors)
  else { return XCTFail() }
  XCTAssertEqual(poll(&rejected, false), .finished)
  XCTAssertEqual(ports.port.take()?.error, 4)
  guard case .ready(var cancelled) = begin(name, 0, vectors) else { return XCTFail() }
  XCTAssertEqual(
    ports.port.cancel(key: 49) { XCTAssertTrue(cancelled.matches(port: ports.id, operation: $0)) },
    1)
  XCTAssertEqual(poll(&cancelled, true), .finished)
  XCTAssertEqual(ports.port.take()?.error, 26)
  XCTAssertEqual(pump(10, true) ?? [], [])
  guard case .ready(var cork) = begin(name, 2, vectors) else { return XCTFail() }
  XCTAssertEqual(poll(&cork, true), .finished)
  XCTAssertEqual(ports.port.take()?.result0, 3)
  // The application can reuse these pins as soon as its Net result arrives.
  mem[7] = 6
  XCTAssertNil(pump(11, true))
  guard case .ready(var push) = begin(name, 1, [last]) else { return XCTFail() }
  XCTAssertEqual(poll(&push, true), .finished)
  let p = ports.port.take()
  XCTAssertEqual(p?.key, 49)
  XCTAssertEqual(p?.kind, 7)
  XCTAssertEqual(p?.error, 0)
  XCTAssertEqual(p?.result0, 1)
  XCTAssertEqual(pump(12, false), [7, 0, 255, 6])
  XCTAssertEqual(stream.connection.unacknowledged, 0)
  XCTAssertEqual(pump(13, true), [7, 0, 255, 6])
  XCTAssertEqual(stream.connection.unacknowledged, 4)
  let room = stream.connection.outputRoom
  XCTAssertGreaterThan(room, 128)
  XCTAssertLessThan(room, mem.count)
  guard case .ready(var big) = begin(name, 0, [.init(mem)]) else { return XCTFail() }
  XCTAssertEqual(poll(&big, true), .finished)
  XCTAssertEqual(ports.port.take()?.result0, UInt64(room))
  guard case .ready(var pending) = begin(name, 0, [first]) else { return XCTFail() }
  XCTAssertEqual(poll(&pending, true), .waiting)
  XCTAssertNil(ports.port.take())
  XCTAssertTrue(
    stream.connection.input(tcpSegment(incoming.encode(105, 47, 16, 128, [], []))!, at: 14) { _ in
      true
    })
  XCTAssertEqual(pump(15, true), Array(mem.prefix(128)))
  XCTAssertEqual(poll(&pending, true), .waiting)
  stream.connection.abort()
  XCTAssertEqual(poll(&pending, true), .finished)
  XCTAssertEqual(poll(&pending, true), .inactive)
  XCTAssertEqual(ports.port.take()?.error, 61)
  XCTAssertEqual(freed, 6)
  XCTAssertEqual(ports.refs, 0)
}
