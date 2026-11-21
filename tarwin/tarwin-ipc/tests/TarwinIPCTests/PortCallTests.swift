import TarwinABI
import TarwinIPC
import TarwinIPCObservers
import TarwinObject
import TarwinSyscall
import XCTest

private struct Notifications: PortRingWork {
  var ringEvents: [PortQueueEvent] = []
  var accept = true, submitters: [UInt64] = []
  mutating func capture(
    process: UInt64, port: UInt64, record: borrowing RingRecord,
    queue: inout CompletionPort
  ) -> Bool {
    guard accept, let op = queue.reserve(object: port, key: UInt64(record.words[0]), kind: 1)
    else { return false }
    submitters.append(process)
    XCTAssertEqual(queue.finish(op, at: 100) { PortPacket() }, 1)
    return true
  }
  var changes: [UInt32] = []
  mutating func portEvent(_ event: PortQueueEvent) {
    if case .readiness(_, let signals) = event {
      changes.append(signals)
    } else {
      ringEvents.append(event)
    }
  }
  var wake: [UInt64] = []
  var jobs: [(UInt64, UInt64, PortOperation)] = []
  mutating func wakeOne(port: UInt64) { wake.append(port) }
  mutating func scheduleCancel(port: UInt64, source: UInt64, operation: PortOperation) {
    jobs.append((port, source, operation))
  }
}

private final class PortFixture: PortNamespace {
  let headers = UnsafeMutableBufferPointer<ObjectHeader>.allocate(capacity: 3)
  let slab = UnsafeMutableBufferPointer<PortSlot>.allocate(capacity: 2)
  let cells = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 4)
  var table: HandleTable
  var entry: PortObject
  var work = Notifications()
  var creates = 0, reads = 0, fault = false
  let userRange: Range<UInt64> = 0x2000..<0x2040
  init() {
    let ids = KoidSource()
    for i in headers.indices {
      (headers.baseAddress! + i).initialize(
        to: ObjectHeader(
          source: ids, ownerJob: 9,
          kind: i == 2 ? TarwinKind.event : TarwinKind.port, maximumRights: PortObject.initialRights
        )!)
    }
    slab.initialize(repeating: PortSlot())
    table = HandleTable(storage: cells, salt: 3)!
    entry = PortObject(header: .init(headers.baseAddress!), storage: slab)!
  }
  deinit {
    table.drain { _ in XCTFail() }
    for i in headers.indices { XCTAssertEqual(headers[i].release(), .destroy) }
    headers.deinitialize()
    headers.deallocate()
    cells.deinitialize()
    cells.deallocate()
    slab.deinitialize()
    slab.deallocate()
  }
  func withNewPort(_ body: (inout PortObject, inout HandleTable) -> CallResult) -> CallResult {
    creates += 1
    return body(&entry, &table)
  }
  func withPort(
    named: UInt64,
    _ body: (
      inout PortObject, borrowing HandleTable, inout Notifications, UInt64
    ) -> CallResult
  ) -> CallResult {
    body(&entry, table, &work, 0xbeef)
  }
  func readWords(from addr: UInt64, into dst: UnsafeMutableBufferPointer<UInt64>) -> Bool {
    reads += 1
    guard addr == userRange.lowerBound, dst.count == 8 else { return false }
    let input: [UInt64] = [13, 0x3456_0123_0000_0007, 0xfe, 0x41_0000_0001, 0, 5, 6, .max]
    for i in dst.indices {
      dst[i] = input[i]
      if fault && i == 4 { return false }
    }
    return true
  }
  func call(_ number: UInt64, _ words: UInt64...) -> CallResult {
    var calls = PortCalls(context: self)
    return words.withUnsafeBufferPointer { calls.invoke(number: number, words: $0) }
  }
  func queue<R>(_ body: (inout CompletionPort) -> R) -> R {
    entry.withQueue(notify: { work.portEvent($0) }, body)
  }
  func enter(_ name: UInt64, process: UInt64 = 22, deadline: UInt64 = .max) -> PortEnterDecision {
    entry.prepareEnter(
      name: name, process: process, table: table, deadline: deadline, now: 9, work: &work)
  }
}

final class PortCallTests: XCTestCase {
  func testBoundEnterAndEagerPublication() {
    let m = SharedMemory(stride: 64)
    let f = PortFixture()
    defer { withExtendedLifetime(m) {} }
    var sender = RingEndpoint(fresh: m.view, completion: false, producer: true)!
    var receiver = RingEndpoint(fresh: m.view, completion: true, producer: false)!
    XCTAssertFalse(f.entry.bindFreshRing(process: 0, words: m.view))
    XCTAssertTrue(f.entry.bindFreshRing(process: 22, words: m.view))
    XCTAssertFalse(f.entry.bindFreshRing(process: 99, words: m.view))
    let name = f.call(TarwinCall.portCreate, 0).first
    guard case .installed(let narrow) = f.table.derive(name, rights: 8, duplicate: true) else {
      return XCTFail()
    }
    var rec = RingRecord()
    rec.words[0] = 172
    XCTAssertEqual(sender.push(rec), .transferred(notifyPeer: false))
    XCTAssertEqual(f.enter(0), .error(2))
    XCTAssertEqual(f.enter(narrow), .error(4))
    XCTAssertEqual(f.enter(name, process: 23), .error(4))
    XCTAssertEqual(m.cells[32].load(ordering: .acquiring), 0)
    f.work.accept = false
    XCTAssertEqual(f.enter(name, deadline: 9), .error(25))
    XCTAssertEqual(f.enter(name, deadline: 10), .wouldSleep)
    XCTAssertEqual(m.cells[32].load(ordering: .acquiring), 0)
    XCTAssertEqual(receiver.pop(into: &rec), .wait)
    f.work.accept = true
    XCTAssertEqual(f.enter(name, deadline: 0), .ready)
    XCTAssertEqual(f.work.submitters, [22])
    XCTAssertEqual(m.cells[32].load(ordering: .acquiring), 1)
    XCTAssertTrue(f.work.ringEvents.contains(.notifyPeer(f.headers[0].koid, completion: true)))
    XCTAssertEqual(receiver.pop(into: &rec), .transferred(notifyPeer: true))
    XCTAssertEqual(rec.words[0], 172)
    XCTAssertEqual(f.enter(name), .wouldSleep)
    XCTAssertEqual(f.work.changes, [1, 0])
    // A completed post must be visible even if the reader only polls.
    XCTAssertEqual(f.call(TarwinCall.portPost, name, 0x2000).code, 0)
    XCTAssertEqual(receiver.pop(into: &rec), .transferred(notifyPeer: true))
    XCTAssertEqual(rec.words[0], 13)
    XCTAssertEqual(f.enter(name, deadline: 0), .error(25))
    XCTAssertEqual(f.work.changes, [1, 0, 1, 0])
    m.cells[Int(RingFormat.completionConsumer / 4)].store(77, ordering: .releasing)
    XCTAssertEqual(f.enter(name), .error(23))
    XCTAssertEqual(f.work.submitters, [22])
  }

  func testPublishedRinglessPortCannotChangeMapping() {
    let m = SharedMemory(stride: 64)
    let f = PortFixture()
    let name = f.call(TarwinCall.portCreate, 0).first
    XCTAssertFalse(f.entry.bindFreshRing(process: 22, words: m.view))
    XCTAssertEqual(f.enter(name), .error(10))
    XCTAssertNil(PortCalls(context: f).argumentCount(for: TarwinCall.portEnter))
  }

  func testMappedRingRetainsOverflowUntilSpaceAndRearmsAfterAck() {
    let m = SharedMemory(stride: 64), f = PortFixture()
    defer { withExtendedLifetime(m) {} }
    var reader = RingEndpoint(fresh: m.view, completion: true, producer: false)!
    XCTAssertTrue(f.entry.bindFreshRing(process: 22, words: m.view))
    let name = f.call(TarwinCall.portCreate, 0).first
    for key: UInt64 in 0..<67 {
      var user = PortPacket()
      user.key = key
      XCTAssertEqual(f.queue { $0.post(user) }, key < 66)
    }
    var record = RingRecord()
    for i in 0..<64 {
      XCTAssertEqual(reader.pop(into: &record), .transferred(notifyPeer: true))
      XCTAssertEqual(record.words[0], UInt32(i))
    }
    XCTAssertEqual(f.enter(name), .ready)
    for i in 64..<66 {
      XCTAssertEqual(reader.pop(into: &record), .transferred(notifyPeer: true))
      XCTAssertEqual(record.words[0], UInt32(i))
    }
    XCTAssertEqual(f.enter(name), .wouldSleep)
    guard let op = f.queue({ $0.reserve(object: 19, key: 55, kind: 1, repeating: true) }) else {
      return XCTFail()
    }
    XCTAssertEqual(f.queue { $0.more(op, at: 42, PortPacket()) }, .committed(wake: 1))
    XCTAssertEqual(f.enter(name), .ready)
    XCTAssertFalse(f.work.ringEvents.contains(.rearm(f.headers[0].koid, op)))
    XCTAssertEqual(reader.pop(into: &record), .transferred(notifyPeer: true))
    XCTAssertEqual(record.words[7], 1)
    XCTAssertEqual(f.enter(name), .wouldSleep)
    XCTAssertEqual(f.work.ringEvents.filter { $0 == .rearm(f.headers[0].koid, op) }.count, 1)
  }
  func testReadableFollowsValidatedRingConsumptionNotPublication() {
    let f = PortFixture()
    let m = SharedMemory(stride: 64)
    let other = SharedMemory(stride: 64)
    defer { withExtendedLifetime((m, other)) {} }
    var p = RingEndpoint(fresh: m.view, completion: true, producer: true)!
    var second = RingEndpoint(fresh: m.view, completion: true, producer: true)!
    var wrong = RingEndpoint(fresh: other.view, completion: true, producer: true)!
    var c = RingEndpoint(fresh: m.view, completion: true, producer: false)!
    let name = f.call(TarwinCall.portCreate, 0).first
    XCTAssertEqual(f.call(TarwinCall.portPost, name, 0x2000).code, 0)
    XCTAssertEqual(f.queue { $0.publishNext(to: &p) }, .transferred(notifyPeer: false))
    XCTAssertNil(f.queue { $0.take() })
    // The idle publisher must hear about progress even when the ring isn't full.
    XCTAssertNil(f.queue { $0.publishNext(to: &p) })
    XCTAssertNil(f.queue { $0.acknowledgeConsumed(from: &p) { _ in XCTFail() } })
    XCTAssertEqual(f.queue { $0.acknowledgeConsumed(from: &second) { _ in XCTFail() } }, .wrongSide)
    XCTAssertEqual(f.queue { $0.acknowledgeConsumed(from: &wrong) { _ in XCTFail() } }, .wrongSide)
    XCTAssertEqual(f.headers[0].signals, 1)
    var record = RingRecord()
    XCTAssertEqual(c.pop(into: &record), .transferred(notifyPeer: true))
    XCTAssertNil(f.queue { $0.acknowledgeConsumed(from: &p) { _ in XCTFail() } })
    XCTAssertEqual(f.work.changes, [1, 0])
    for _ in 0..<2 { XCTAssertEqual(f.call(TarwinCall.portPost, name, 0x2000).code, 0) }
    XCTAssertEqual(f.queue { $0.publishNext(to: &p) }, .transferred(notifyPeer: false))
    XCTAssertEqual(c.pop(into: &record), .transferred(notifyPeer: false))
    XCTAssertNil(f.queue { $0.acknowledgeConsumed(from: &p) { _ in XCTFail() } })
    XCTAssertEqual(f.headers[0].signals, 1)  // A second record remains in the kernel.
    f.queue { $0.close() }
    f.queue { $0.close() }
    XCTAssertEqual(f.work.changes, [1, 0, 1, 0])
    XCTAssertEqual(f.call(TarwinCall.portPost, name, 0x2000).code, 2)
  }
  func testCheckedPublicationAndUntrustedPost() {
    let f = PortFixture()
    XCTAssertEqual(f.call(TarwinCall.portCreate, 1).code, 1)
    XCTAssertEqual(f.creates, 0)
    let created = f.call(TarwinCall.portCreate, 0)
    let name = created.first
    XCTAssertEqual(created.code, 0)
    XCTAssertEqual(f.call(TarwinCall.portCreate, 0).code, 23)
    guard
      case .installed(let other) = f.table.install(.init(f.headers.baseAddress! + 1), rights: 8),
      case .installed(let wrong) = f.table.install(.init(f.headers.baseAddress! + 2), rights: 8),
      case .installed(let reduced) = f.table.derive(name, rights: 0, duplicate: true)
    else { return XCTFail() }
    let addr = f.userRange.lowerBound
    for bad in [addr + 8, addr - 8, addr + 1, UInt64.max - 7] {
      XCTAssertEqual(f.call(TarwinCall.portPost, name, bad).code, 1)
    }
    XCTAssertEqual(f.reads, 0)
    f.fault = true
    XCTAssertEqual(f.call(TarwinCall.portPost, name, addr).code, 1)
    f.fault = false
    for (handle, code): (UInt64, UInt32) in [(other, 2), (wrong, 3), (reduced, 4)] {
      XCTAssertEqual(f.call(TarwinCall.portPost, handle, addr).code, code)
    }
    XCTAssertEqual(f.queue { $0.available }, 0)
    XCTAssertTrue(f.work.wake.isEmpty)
    for _ in 0..<2 { XCTAssertEqual(f.call(TarwinCall.portPost, name, addr).code, 0) }
    XCTAssertEqual(f.call(TarwinCall.portPost, name, addr).code, 24)
    XCTAssertEqual(f.work.wake, [f.headers[0].koid, f.headers[0].koid])
    XCTAssertEqual(f.work.changes, [1])
    XCTAssertEqual(f.headers[0].signals, 1)
    let packet = f.queue { $0.take()! }
    XCTAssertEqual(f.headers[0].signals, 1)
    XCTAssertNotNil(f.queue { $0.take() })
    XCTAssertEqual(f.headers[0].signals, 0)
    XCTAssertEqual(f.work.changes, [1, 0])
    XCTAssertEqual(
      [packet.key, UInt64(packet.kind), UInt64(packet.flags), packet.timestamp],
      [13, 0, 0x41, 0xbeef])
    XCTAssertEqual(
      [UInt64(packet.error), UInt64(packet.subsystem), UInt64(packet.errorFlags), packet.detail],
      [7, 0x123, 0x3456, 0xfe])
    XCTAssertEqual([packet.result0, packet.result1, packet.aux], [0, 5, 6])
    XCTAssertTrue(f.table.close(name, retire: { _ in XCTFail() }))
    XCTAssertEqual(f.call(TarwinCall.portPost, name, addr).code, 2)
  }
  func testCancelQueuesEveryMatchingBackendAndOnlyThoseBackends() {
    let f = PortFixture()
    let name = f.call(TarwinCall.portCreate, 0).first
    guard case .installed(let reduced) = f.table.derive(name, rights: 0, duplicate: true),
      let a = f.queue({ $0.reserve(object: 99, key: 4, kind: 1) }),
      let b = f.queue({ $0.reserve(object: 100, key: 4, kind: 2) })
    else { return XCTFail() }
    XCTAssertEqual(f.call(TarwinCall.portCancel, reduced, 9).first, 0)
    let result = f.call(TarwinCall.portCancel, reduced, 4)
    XCTAssertEqual(result.code, 0)
    XCTAssertEqual(result.first, 2)
    XCTAssertEqual(f.call(TarwinCall.portCancel, reduced, 4).first, 0)
    XCTAssertEqual(f.work.jobs.map { $0.0 }, [f.headers[0].koid, f.headers[0].koid])
    XCTAssertEqual(f.work.jobs.map { $0.1 }, [99, 100])
    XCTAssertEqual(f.work.jobs.map { $0.2 }, [a, b])
    XCTAssertNil(f.queue { $0.take() })
    for job in f.work.jobs {
      XCTAssertEqual(f.queue { $0.finishCancellation(job.2, at: 101) }, 1)
      XCTAssertEqual(f.queue { $0.take()?.error }, 26)
    }
  }
}
