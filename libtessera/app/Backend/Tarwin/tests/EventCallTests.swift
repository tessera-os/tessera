import LibTesseraTarwin
import TarwinABI
import TarwinObject
import TarwinObjectCalls
import TarwinSyscall
import XCTest

private final class EventFixture: EventNamespace {
  let cells: UnsafeMutableBufferPointer<HandleCell>
  let headers: UnsafeMutableBufferPointer<ObjectHeader>
  var table: HandleTable
  var record: EventEndpoints
  var creators = true, changes: [UInt32] = []
  init(pair: Bool, slots: Int = 8) {
    cells = .allocate(capacity: slots)
    table = HandleTable(storage: cells, salt: 33)!
    headers = .allocate(capacity: pair ? 2 : 1)
    let ids = KoidSource()
    for i in headers.indices {
      (headers.baseAddress! + i).initialize(
        to: ObjectHeader(
          source: ids, ownerJob: 11,
          kind: pair ? TarwinKind.eventPair : TarwinKind.event,
          maximumRights: EventEndpoints.initialRights)!)
    }
    record = EventEndpoints(
      first: .init(headers.baseAddress!), second: pair ? .init(headers.baseAddress! + 1) : nil)!
  }
  deinit {
    table.drain { p in self.record.destroy(p) { _ in } }
    if creators { for i in headers.indices { _ = headers[i].release() } }
    headers.deinitialize()
    headers.deallocate()
    cells.deinitialize()
    cells.deallocate()
  }
  func withNewEvent(pair: Bool, _ body: (inout EventEndpoints, inout HandleTable) -> CallResult)
    -> CallResult
  {
    guard creators else { return CallResult(status: syscallStatus(23, 1)) }
    let r = body(&record, &table)
    for i in headers.indices { _ = headers[i].release() }
    creators = false
    return r
  }
  func withEvent(
    named: UInt64,
    _ body: (borrowing EventEndpoints, borrowing HandleTable, (UnsafePointer<ObjectHeader>) -> Void)
      -> CallResult
  ) -> CallResult {
    body(record, table, { self.changes.append($0.pointee.signals) })
  }
  func close(_ name: UInt64) {
    XCTAssertTrue(
      table.close(name) { p in self.record.destroy(p) { self.changes.append($0.pointee.signals) } })
  }
}

private struct EventGate: NativeGate {
  var provider: EventCalls<EventFixture>
  let isa: CallISA
  mutating func enter(number: UInt64, registers: CallRegisters) -> CallResult {
    var scratch = [UInt64](repeating: 0, count: 3)
    return scratch.withUnsafeMutableBufferPointer {
      let result = dispatchCall(
        isa: isa, savedPC: isa == .rv64 ? 4096 : 4096 + isa.instructionWidth,
        libraryCode: 4096..<4112, userRange: 0..<0, number: number, registers: registers,
        scratch: $0, provider: &provider)
      guard case .returned(let r) = result else {
        XCTFail()
        return CallResult(status: .max)
      }
      return r
    }
  }
}

final class EventCallTests: XCTestCase {
  func testMovingAnEndKeepsItLiveUntilTheReceivedNameCloses() {
    let f = EventFixture(pair: true)
    var gate = EventGate(provider: EventCalls(context: f), isa: .rv64)
    let pair = NativeEvents.pair(gate: &gate)
    let storage = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 1)
    var receiver = HandleTable(storage: storage, salt: 55)!
    defer {
      receiver.drain { h in f.record.destroy(h) { _ in } }
      storage.deinitialize()
      storage.deallocate()
    }
    var received: UInt64 = 0
    let moved = [pair.first].withUnsafeBufferPointer { names in
      f.table.moveForChannel(names) { (grant: consuming ObjectGrant) in
        guard case .installed(let n) = receiver.installMoved(grant) else { return XCTFail() }
        received = n
      }
    }
    XCTAssertEqual(moved, .allowed)
    XCTAssertNotEqual(received, pair.first)
    f.record.destroy(.init(f.headers.baseAddress!)) { _ in XCTFail() }
    XCTAssertEqual(NativeEvents.signal(pair.second, set: 8, clear: 0, gate: &gate).code, 0)
    XCTAssertEqual(
      f.record.signal(name: received, set: 8, clear: 0, in: receiver, notify: { _ in }), .ok)
    XCTAssertEqual(f.headers[1].signals, 8)
    XCTAssertTrue(
      receiver.close(received) { h in f.record.destroy(h) { f.changes.append($0.pointee.signals) } }
    )
    XCTAssertEqual(f.headers[1].signals, 12)
    f.record.destroy(.init(f.headers.baseAddress!)) { _ in XCTFail() }
  }

  func testPairSignalsPeerAndClosesOnlyAtLastReference() {
    for isa in [CallISA.aarch64, .rv64, .x64] {
      let f = EventFixture(pair: true)
      var g = EventGate(provider: EventCalls(context: f), isa: isa)
      let pair = NativeEvents.pair(gate: &g)
      XCTAssertEqual(pair.status, 0)
      XCTAssertNotEqual(pair.first, pair.second)
      XCTAssertEqual(NativeEvents.signal(pair.first, set: 0x8000_0008, clear: 0, gate: &g).code, 0)
      XCTAssertEqual(f.headers[0].signals, 0)
      XCTAssertEqual(f.headers[1].signals, 0x8000_0008)
      XCTAssertEqual(NativeEvents.signal(pair.second, set: 8, clear: 8, gate: &g).code, 0)
      XCTAssertEqual(NativeEvents.signal(pair.second, set: 8, clear: 0, gate: &g).code, 0)
      guard case .installed(let reduced) = f.table.derive(pair.first, rights: 128, duplicate: true)
      else { return XCTFail() }
      XCTAssertEqual(NativeEvents.signal(reduced, set: 8, clear: 0, gate: &g).code, 4)
      f.close(pair.first)
      XCTAssertEqual(NativeEvents.signal(pair.first, set: 8, clear: 0, gate: &g).code, 2)
      XCTAssertEqual(f.headers[1].signals, 0x8000_0008)
      f.close(reduced)
      XCTAssertEqual(f.headers[1].signals, 0x8000_000c)
      XCTAssertEqual(NativeEvents.signal(pair.second, set: 0, clear: 8, gate: &g).code, 27)
      XCTAssertEqual(NativeEvents.signal(pair.second, set: 0, clear: 4, gate: &g).code, 1)
      XCTAssertEqual(f.changes, [0x8000_0008, 8, 0x8000_000c])
    }
  }
  func testStandaloneMaskAndPairPublicationLimit() {
    let f = EventFixture(pair: false)
    var g = EventGate(provider: EventCalls(context: f), isa: .aarch64)
    XCTAssertEqual(NativeEvents.create(initial: 1 << 16, gate: &g).code, 1)
    XCTAssertTrue(f.creators)
    let h = NativeEvents.create(initial: 0x0100_0008, gate: &g)
    XCTAssertEqual(h.status, 0)
    XCTAssertEqual(h.second, 0)
    XCTAssertEqual(NativeEvents.signal(h.first, set: 0, clear: 8, gate: &g).code, 0)
    XCTAssertEqual(f.headers[0].signals, 0x0100_0000)
    XCTAssertEqual(
      g.enter(
        number: LibTesseraTarwin.TarwinCall.objectSignal,
        registers: CallRegisters(h.first, 1 << 40, 0)
      ).code, 1)
    XCTAssertEqual(f.changes, [0x0100_0000])
    let full = EventFixture(pair: true, slots: 1)
    var other = EventGate(provider: EventCalls(context: full), isa: .aarch64)
    let rejected = NativeEvents.pair(gate: &other)
    XCTAssertEqual(rejected.code, 33)
    XCTAssertEqual([rejected.first, rejected.second], [0, 0])
    XCTAssertEqual(full.table.count, 0)
  }
}
