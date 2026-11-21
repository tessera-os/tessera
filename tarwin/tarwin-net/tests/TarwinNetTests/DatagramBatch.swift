import TarwinIPC
import TarwinObject
import TarwinSyscall
import XCTest

@testable import TarwinNet

func checkBatch(
  caller: inout ProcessExecution, name: UInt64, port: UInt64, ports: inout AcceptPorts,
  object: UnsafePointer<ObjectHeader>, mailbox: UdpMailbox, expectedPeer: [UInt8],
  makePacket: ([UInt8]) -> OutputResult
) {
  let ram = UnsafeMutableRawBufferPointer.allocate(byteCount: 176, alignment: 8)
  defer { ram.deallocate() }
  func span(_ r: Range<Int>) -> UnsafeMutableRawBufferPointer { .init(rebasing: ram[r]) }
  let rows = span(1..<169)
  let a = span(170..<171)
  let b = span(172..<174)
  let c = span(175..<176)
  func begin(
    _ flags: UInt32, _ messages: Int = 3, _ vectors: Int = 3,
    _ range: UnsafeMutableRawBufferPointer? = nil
  ) -> EndpointIoStart<DatagramReceive> {
    DatagramReceive.beginMany(
      call: TarwinCall.endpointReceiveMany, caller: caller, name: name, port: port, key: 99,
      flags: flags,
      buffers: [[a], [b], [c]], records: range ?? rows, maxMessages: messages, maxVectors: vectors,
      ports: &ports, permitted: true,
      resolve: { $0 == object ? mailbox : nil }, retire: { _ in XCTFail() })
  }
  func input(_ payload: [UInt8]) {
    guard case .packet(let ip) = makePacket(payload) else { return XCTFail() }
    XCTAssertEqual(
      mailbox.input(ip, interface: mailbox.interface, epoch: mailbox.epoch, at: 77) { _, _, _ in
        true
      }, .queued)
  }
  var releases = 0
  func poll(_ op: inout DatagramReceive) -> ReceiveProgress {
    op.poll(
      at: 22, ports: &ports, permitted: true,
      releasePins: { releases += 1 }, retire: { _ in XCTFail() })
  }
  ram.initializeMemory(as: UInt8.self, repeating: 0xab)
  guard case .invalid = begin(0, 2), case .invalid = begin(0, 3, 2),
    case .invalid = begin(0, 3, 3, span(1..<168)),
    case .unsupported = begin(4), case .ready(var cancelled) = begin(0)
  else { return XCTFail() }
  XCTAssertEqual(poll(&cancelled), .waiting)
  input([9, 8])
  input([7])
  let id = ports.id
  XCTAssertEqual(
    ports.port.cancel(owner: OperationHandle(process: caller.header.pointee.koid, name: name)!) {
      XCTAssertTrue(cancelled.matches(port: id, operation: $0))
    }, 1)
  XCTAssertEqual(poll(&cancelled), .finished)
  XCTAssertEqual(ports.port.take()?.error, 26)
  XCTAssertTrue(ram.allSatisfy { $0 == 0xab })
  XCTAssertEqual(mailbox.count, 2)
  for peek: UInt32 in [1, 0] {
    ram.initializeMemory(as: UInt8.self, repeating: 0xab)
    guard case .ready(var op) = begin(peek | 2) else { return XCTFail() }
    XCTAssertEqual(poll(&op), .finished)
    let result = ports.port.take()
    XCTAssertEqual(result?.result0, 2)
    XCTAssertEqual(result?.aux, 0)
    XCTAssertEqual(result?.key, 99)
    XCTAssertEqual(result?.error, 0)
    var expected = [UInt8](repeating: 0xab, count: ram.count)
    for i in 0..<2 {
      let start = 1 + i * 56
      expected.replaceSubrange((start + 12)..<(start + 16), with: [i == 0 ? 1 : 0, 0, 0, 0])
      expected.replaceSubrange((start + 16)..<(start + 48), with: expectedPeer)
      expected.replaceSubrange((start + 48)..<(start + 56), with: [1, 0, 0, 0, 0, 0, 0, 0])
    }
    expected[170] = 9
    expected[172] = 7
    XCTAssertEqual(Array(ram), expected)
    XCTAssertEqual(mailbox.count, peek == 0 ? 0 : 2)
  }
  XCTAssertEqual(releases, 3)
}
