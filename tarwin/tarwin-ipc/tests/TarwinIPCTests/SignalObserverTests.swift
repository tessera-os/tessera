import TarwinIPC
import TarwinIPCObservers
import TarwinObject
import XCTest

private final class ObserverPort: SignalPorts {
  let id: UInt64
  let slab: UnsafeMutableBufferPointer<PortSlot>
  var port: CompletionPort
  var wakes = 0
  init(_ id: UInt64) {
    self.id = id
    slab = .allocate(capacity: 8)
    slab.initialize(repeating: PortSlot())
    port = CompletionPort(storage: slab)!
  }
  deinit {
    slab.deinitialize()
    slab.deallocate()
  }
  func withPort<R>(_ id: UInt64, _ body: (inout CompletionPort) -> R) -> R? {
    id == self.id && !port.closed ? body(&port) : nil
  }
  func wake(port: UInt64, count: Int) {
    XCTAssertEqual(port, id)
    wakes += count
  }
}

private final class ObserverFixture {
  let headers = UnsafeMutableBufferPointer<ObjectHeader>.allocate(capacity: 3)
  let cells = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 5)
  let slab = UnsafeMutableBufferPointer<ObserverSlot>.allocate(capacity: 4)
  var table: HandleTable
  var observers: SignalObservers
  var ports: ObserverPort
  let source, destination, reduced, duplicate, wrong: UInt64
  init() {
    let ids = KoidSource()
    for (i, kind) in [TarwinKind.event, TarwinKind.port, TarwinKind.event].enumerated() {
      (headers.baseAddress! + i).initialize(
        to: ObjectHeader(source: ids, ownerJob: 1, kind: kind, maximumRights: 129)!)
    }
    slab.initialize(repeating: ObserverSlot())
    observers = SignalObservers(object: .init(headers.baseAddress!), storage: slab)
    ports = ObserverPort(headers[1].koid)
    table = HandleTable(storage: cells, salt: 1)!
    guard case .installed(let a) = table.install(.init(headers.baseAddress!), rights: 129),
      case .installed(let b) = table.install(.init(headers.baseAddress! + 1), rights: 0),
      case .installed(let c) = table.derive(a, rights: 0, duplicate: true),
      case .installed(let d) = table.derive(a, rights: 128, duplicate: true),
      case .installed(let e) = table.install(.init(headers.baseAddress! + 2), rights: 128)
    else { fatalError() }
    (source, destination, reduced, duplicate, wrong) = (a, b, c, d, e)
  }
  deinit {
    observers.destroy(at: 90, ports: &ports)
    table.drain { _ in }
    for i in headers.indices { _ = headers[i].release() }
    headers.deinitialize()
    headers.deallocate()
    cells.deinitialize()
    cells.deallocate()
    slab.deinitialize()
    slab.deallocate()
  }
  func arm(
    _ mode: SignalWaitMode, _ key: UInt64, name: UInt64? = nil,
    to: UInt64? = nil, mask: UInt32 = 9
  ) -> SignalArmResult {
    observers.arm(
      process: 77, source: name ?? source, mask: mask, mode: mode,
      destination: to ?? destination, key: key, table: table, at: 1, ports: &ports)
  }
  func set(_ mask: UInt32, _ time: UInt64) {
    _ = headers[0].updateSignals(clear: .max, set: mask)
    observers.changed(at: time, ports: &ports)
  }
  func take(_ now: UInt64) -> PortPacket? {
    var next: PortOperation?
    let packet = ports.port.take { next = $0 }
    if let next { observers.consumed(next, port: ports.id, at: now, ports: &ports) }
    return packet
  }
}

final class SignalObserverTests: XCTestCase {
  func testArmOrderImmediateLevelEdgesAndBackpressure() {
    let f = ObserverFixture()
    f.set(8, 1)
    XCTAssertEqual(f.arm(.once, 1), .armed)
    XCTAssertEqual(f.take(1)?.result0, 8)
    XCTAssertEqual(f.observers.count, 0)
    XCTAssertEqual(f.arm(.edge, 2), .armed)
    XCTAssertNil(f.take(1))
    XCTAssertEqual(f.arm(.level, 3, name: f.duplicate), .armed)
    // The first level delivery cannot overtake the earlier edge.
    XCTAssertNil(f.take(1))
    f.set(9, 2)
    f.set(0, 3)
    f.set(8, 4)
    XCTAssertEqual(f.ports.port.available, 2)
    let edge = f.take(4)!
    XCTAssertEqual([edge.key, edge.result0, UInt64(edge.flags), edge.timestamp], [2, 1, 1, 2])
    let level = f.take(5)!
    XCTAssertEqual([level.key, level.result0, UInt64(level.flags)], [3, 8, 1])
    f.set(0, 6)
    XCTAssertEqual(f.take(6)?.result0, 8)  // coalesced rise during the first unread packet
    XCTAssertEqual(f.take(6)?.key, 3)
    XCTAssertNil(f.take(6))
    f.set(1, 7)
    XCTAssertEqual(f.take(7)?.key, 2)
    XCTAssertEqual(f.take(7)?.key, 3)
    XCTAssertEqual(f.take(8)?.key, 3)  // still asserted after dequeue
    XCTAssertEqual(f.ports.port.available, 1)
  }

  func testCancellationFollowsOriginalNameAndPortClosureDetaches() {
    let f = ObserverFixture()
    XCTAssertEqual(f.arm(.once, 1, name: f.reduced), .denied)
    XCTAssertEqual(f.arm(.once, 1, name: f.wrong), .invalidHandle)
    XCTAssertEqual(f.arm(.once, 1, name: 0), .invalidHandle)
    XCTAssertEqual(f.arm(.once, 1, to: f.source), .wrongType)
    XCTAssertEqual(f.arm(.once, 1, mask: 0), .invalidArgument)
    XCTAssertEqual(f.arm(.edge, 7), .armed)
    XCTAssertEqual(f.arm(.once, 7, name: f.duplicate), .armed)
    var requests: [PortOperation] = []
    XCTAssertTrue(f.table.close(f.source, retire: { _ in XCTFail() }))
    XCTAssertEqual(
      f.ports.port.cancel(owner: .init(process: 77, name: f.source)!) { requests.append($0) }, 1)
    let op = requests[0]
    XCTAssertEqual(f.ports.port.source(of: op), f.headers[0].koid)
    f.observers.cancelled(op, port: f.ports.id + 1, at: 2, ports: &f.ports)
    XCTAssertEqual(f.observers.count, 2)
    f.observers.cancelled(op, port: f.ports.id, at: 3, ports: &f.ports)
    XCTAssertEqual(f.take(3)?.error, 26)
    f.set(8, 4)
    XCTAssertEqual(f.take(4)?.result0, 8)
    XCTAssertNil(f.ports.port.source(of: op))
    XCTAssertEqual(f.arm(.edge, 9, name: f.duplicate), .armed)
    f.ports.port.close { id, token in
      XCTAssertEqual(id, f.headers[0].koid)
      f.observers.portClosed(token, port: f.ports.id)
    }
    XCTAssertEqual(f.observers.count, 0)
    XCTAssertNil(f.take(5))
  }

  func testDestroyFinishesEveryArmedObserverOnce() {
    let f = ObserverFixture()
    for i in 0..<4 { XCTAssertEqual(f.arm(.edge, UInt64(i)), .armed) }
    XCTAssertEqual(f.arm(.once, 4), .limit)
    f.observers.destroy(at: 40, ports: &f.ports)
    XCTAssertEqual(f.observers.count, 0)
    for i in 0..<4 {
      let p = f.take(40)!
      XCTAssertEqual([p.key, UInt64(p.error), p.timestamp], [UInt64(i), 26, 40])
    }
    XCTAssertNil(f.take(41))
  }
}
