import TarwinABI
import TarwinObject
import TarwinSyscall
import XCTest

@testable import TarwinNet

private struct Context: StreamShutdownContext {
  let table: HandleReadView, object: UnsafePointer<ObjectHeader>, stream: TcpAcceptedStream
  var live = true, permitted = true
  func pinCaller(_ visit: (HandleReadView) -> PinResult) -> PinResult {
    live ? visit(table) : .accessDenied
  }
  mutating func withStream(
    _ object: UnsafePointer<ObjectHeader>, _ visit: (TcpAcceptedStream) -> CallResult
  ) -> CallResult {
    guard object == self.object else { return CallResult(status: syscallStatus(23, 6)) }
    guard permitted else { return CallResult(status: syscallStatus(4, 6)) }
    return visit(stream)
  }
  mutating func retire(_ object: UnsafePointer<ObjectHeader>) { XCTFail("retired a live endpoint") }
}
func checkShutdown(
  caller: inout ProcessExecution, name: UInt64, readonly: UInt64, port: UInt64,
  ports: inout AcceptPorts,
  child: UnsafePointer<ObjectHeader>, stream: TcpAcceptedStream, incoming: TcpPath
) {
  var provider = EndpointShutdown(
    Context(table: caller.handleReader, object: child, stream: stream))
  func call(_ handle: UInt64, _ how: UInt64, isa: CallISA = .x64) -> UInt32 {
    var scratch = [UInt64](repeating: 0, count: 8)
    return scratch.withUnsafeMutableBufferPointer {
      switch dispatchCall(
        isa: isa, savedPC: 0x1000 + (isa == .rv64 ? 0 : isa.instructionWidth),
        libraryCode: 0x1000..<0x2000, userRange: 0..<0, number: TarwinCall.endpointShutdown,
        registers: .init(handle, how), scratch: $0, provider: &provider)
      {
      case .returned(let r): return r.code
      default:
        XCTFail()
        return .max
      }
    }
  }
  XCTAssertNil(provider.argumentCount(for: TarwinCall.endpointSend))
  XCTAssertEqual(call(0, 0), 2)
  XCTAssertEqual(call(port, 1), 3)
  XCTAssertEqual(call(readonly, 2), 4)
  XCTAssertEqual(call(readonly, 1), 4)
  XCTAssertEqual(call(name, 1 << 32), 1)
  provider.context.permitted = false
  XCTAssertEqual(call(name, 2), 4)
  provider.context.permitted = true
  provider.context.live = false
  XCTAssertEqual(call(name, 2), 4)
  provider.context.live = true
  XCTAssertEqual(stream.connection.readable, 4)

  let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: 8, alignment: 1)
  defer { buf.deallocate() }
  buf.initializeMemory(as: UInt8.self, repeating: 0xca)
  guard
    case .ready(var rx) = EndpointReceive.begin(
      call: TarwinCall.endpointReceive, caller: caller, name: name, port: port, key: 1,
      flags: 2, buffers: [buf], maxVectors: 1, ports: &ports, permitted: true,
      resolve: { _ in stream }, retire: { _ in XCTFail() })
  else { return XCTFail() }
  func read() -> ReceiveProgress {
    rx.poll(at: 3, ports: &ports, permitted: true, releasePins: {}, retire: { _ in XCTFail() })
  }
  XCTAssertEqual(read(), .waiting)
  for isa: CallISA in [.aarch64, .x64, .rv64] { XCTAssertEqual(call(readonly, 0, isa: isa), 0) }
  XCTAssertEqual(read(), .finished)
  let eof = ports.port.take()
  XCTAssertEqual(eof?.error, 0)
  XCTAssertEqual(eof?.result0, 0)
  XCTAssertTrue(buf.allSatisfy { $0 == 0xca })
  func packet(_ seq: UInt32, _ ack: UInt32, _ flags: UInt8, _ data: [UInt8] = []) {
    XCTAssertTrue(
      stream.connection.input(tcpSegment(incoming.encode(seq, ack, flags, 128, [], data))!, at: 4) {
        _ in true
      })
  }
  packet(105, 43, 24, [7, 8])
  XCTAssertEqual(stream.connection.readable, 0)
  var output: TcpSegment?
  func pump(_ ok: Bool) -> Bool {
    stream.connection.pump(at: 4) {
      output = tcpSegment($0)
      return ok
    }
  }
  XCTAssertTrue(pump(true))
  XCTAssertEqual(output?.ack, 107)
  XCTAssertEqual(output?.window, 512)
  XCTAssertEqual(output?.flags, 16)
  // Reading is shut but application sends are still accepted. Leave this
  // prefix corked across the write shutdown and one failed publication.
  stream.connection.enqueueOutput([0, 3, 255], flags: 2, at: 4)
  XCTAssertFalse(pump(true))
  guard
    case .ready(var tx) = EndpointSend.begin(
      call: TarwinCall.endpointSend, caller: caller, name: name, port: port, key: 2,
      flags: 0, sources: [.init(buf)], maxVectors: 1, ports: &ports, permitted: true,
      resolve: { _ in stream }, retire: { _ in XCTFail() })
  else { return XCTFail() }
  XCTAssertEqual(call(name, 2), 0)
  XCTAssertEqual(call(name, 1), 0)
  XCTAssertEqual(
    tx.poll(at: 4, ports: &ports, permitted: true, releasePins: {}, retire: { _ in XCTFail() }),
    .finished)
  XCTAssertEqual(ports.port.take()?.error, 27)
  XCTAssertFalse(pump(false))
  XCTAssertTrue(pump(true))
  XCTAssertEqual(output.map { Array($0.payload) }, [0, 3, 255])
  XCTAssertEqual(output?.sequence, 43)
  XCTAssertFalse(pump(true))
  packet(107, 46, 16)
  XCTAssertFalse(pump(false))
  XCTAssertEqual(stream.connection.state, .established)
  XCTAssertTrue(pump(true))
  XCTAssertEqual(output?.flags, 17)
  XCTAssertEqual(output?.sequence, 46)
  packet(107, 47, 17)
  XCTAssertEqual(stream.connection.state, .timeWait)
}
