import TarwinIPC
import TarwinObject
import TarwinSyscall
import XCTest

@testable import TarwinNet

func checkReceive(
  caller: inout ProcessExecution, name: UInt64, denied: UInt64, port: UInt64,
  ports: inout AcceptPorts,
  child: UnsafePointer<ObjectHeader>, stream: TcpAcceptedStream, incoming: TcpPath
) {
  let mem = UnsafeMutableRawBufferPointer.allocate(byteCount: 10, alignment: 8)
  defer { mem.deallocate() }
  for i in mem.indices { mem[i] = 0xcd }
  let first = UnsafeMutableRawBufferPointer(rebasing: mem[1..<3])
  let empty = UnsafeMutableRawBufferPointer(start: nil, count: 0)
  let second = UnsafeMutableRawBufferPointer(rebasing: mem[5..<9])
  let dest = [first, empty, second]
  func begin(_ n: UInt64, _ flags: UInt32, _ v: [UnsafeMutableRawBufferPointer]) -> ReceiveStart {
    EndpointReceive.begin(
      call: TarwinCall.endpointReceive, caller: caller, name: n, port: port, key: 41, flags: flags,
      buffers: v, maxVectors: 3, ports: &ports, permitted: true,
      resolve: { $0 == child ? stream : nil }, retire: { _ in XCTFail() })
  }
  guard case .invalid = begin(name, 0, [empty]), case .invalid = begin(name, 0, dest + [empty]),
    case .denied = begin(denied, 0, dest), case .wrongType = begin(port, 0, dest),
    case .unsupported = begin(name, 4, dest)
  else { return XCTFail() }
  var freed = 0
  func poll(_ op: inout EndpointReceive, _ allowed: Bool = true) -> ReceiveProgress {
    op.poll(
      at: 11, ports: &ports, permitted: allowed, releasePins: { freed += 1 },
      retire: { _ in XCTFail() })
  }
  func input(_ seq: UInt32, _ flags: UInt8, _ data: [UInt8]) {
    XCTAssertTrue(
      stream.connection.input(
        tcpSegment(incoming.encode(seq, 43, flags, 128, [], data))!, at: 9, admit: { _ in true }))
  }
  guard case .ready(var waiting) = begin(name, 2, dest), case .full = begin(name, 0, dest) else {
    return XCTFail()
  }
  XCTAssertEqual(poll(&waiting), .waiting)
  XCTAssertEqual(freed, 0)
  XCTAssertNil(ports.port.take())
  input(105, 24, [8, 9])
  XCTAssertEqual(poll(&waiting, false), .finished)
  XCTAssertEqual(ports.port.take()?.error, 4)
  XCTAssertEqual(stream.connection.readable, 6)
  guard case .ready(var cancelled) = begin(name, 0, dest) else { return XCTFail() }
  let id = caller.header.pointee.koid
  for wrong in [
    OperationHandle(process: id + 1, name: name)!, OperationHandle(process: id, name: denied)!,
  ] {
    XCTAssertEqual(ports.port.cancel(owner: wrong) { _ in XCTFail() }, 0)
  }
  XCTAssertEqual(
    ports.port.cancel(owner: OperationHandle(process: id, name: name)!) {
      XCTAssertTrue(cancelled.matches(port: ports.id, operation: $0))
    }, 1)
  XCTAssertEqual(poll(&cancelled), .finished)
  XCTAssertEqual(ports.port.take()?.error, 26)
  XCTAssertTrue(mem.allSatisfy { $0 == 0xcd })
  XCTAssertEqual(stream.connection.readable, 6)
  guard case .ready(var peek) = begin(name, 3, dest) else { return XCTFail() }
  XCTAssertEqual(poll(&peek), .finished)
  XCTAssertEqual(poll(&peek), .inactive)
  let packet = ports.port.take()
  XCTAssertEqual(packet?.key, 41)
  XCTAssertEqual(packet?.kind, 7)
  XCTAssertEqual(packet?.result0, 6)
  XCTAssertEqual(Array(mem), [0xcd, 0, 1, 0xcd, 0xcd, 2, 255, 8, 9, 0xcd])
  XCTAssertEqual(stream.connection.readable, 6)
  guard case .ready(var read) = begin(name, 0, [second]) else { return XCTFail() }
  XCTAssertEqual(poll(&read), .finished)
  XCTAssertEqual(ports.port.take()?.result0, 4)
  XCTAssertEqual(Array(second), [0, 1, 2, 255])
  guard case .ready(var tail) = begin(name, 2, dest) else { return XCTFail() }
  XCTAssertEqual(poll(&tail), .waiting)
  input(107, 17, [])
  XCTAssertEqual(poll(&tail), .finished)
  XCTAssertEqual(ports.port.take()?.result0, 2)
  XCTAssertEqual(Array(first), [8, 9])
  guard case .ready(var eof) = begin(name, 0, dest) else { return XCTFail() }
  XCTAssertEqual(poll(&eof), .finished)
  let done = ports.port.take()
  XCTAssertEqual(done?.error, 0)
  XCTAssertEqual(done?.result0, 0)
  stream.connection.abort()
  guard case .ready(var reset) = begin(name, 0, dest) else { return XCTFail() }
  XCTAssertEqual(poll(&reset), .finished)
  XCTAssertEqual(ports.port.take()?.error, 61)
  guard case .ready(var closed) = begin(name, 0, dest) else { return XCTFail() }
  ports.port.close()
  XCTAssertTrue(
    closed.withdraw(at: 14, ports: &ports, releasePins: { freed += 1 }, retire: { _ in XCTFail() }))
  XCTAssertNil(ports.port.take())
  XCTAssertEqual(freed, 8)
  XCTAssertEqual(ports.refs, 0)
}
