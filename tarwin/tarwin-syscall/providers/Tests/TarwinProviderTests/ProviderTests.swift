import XCTest
import TarwinABI
import TarwinKernelCalls
import TarwinObject
import TarwinSync
import TarwinSyncCalls
import TarwinSyscall

private final class QueueContext: WaitCallContext, ObjectWaitParkContext {
  struct Word: PinnedWaitWord {
    let context: QueueContext
    var physical: WaitAddress { WaitAddress(frame: 1, offset: 0) }
    func load() -> UInt64? { context.fault ? nil : context.value }
  }
  let buckets = UnsafeMutablePointer<AddressBucket>.allocate(capacity: 2)
  let sleepers = UnsafeMutablePointer<AddressSleeper>.allocate(capacity: 2)
  let queue = UnsafeMutablePointer<AddressQueue>.allocate(capacity: 1)
  let objectBuckets = UnsafeMutablePointer<AddressBucket>.allocate(capacity: 2)
  let objectSleepers = UnsafeMutablePointer<AddressSleeper>.allocate(capacity: 2)
  let objectQueue = UnsafeMutablePointer<AddressQueue>.allocate(capacity: 1)
  var waits: UnsafePointer<AddressQueue> { UnsafePointer(queue) }
  var objectWaits: UnsafePointer<AddressQueue> { UnsafePointer(objectQueue) }
  var objectWaitActive = false
  var value: UInt64 = 0
  var fault = false
  var now: UInt64 = 1
  var threadSlot = 0
  var completed: [(SleepTicket, WaitEnd)] = []
  var parked = 0
  let source = KoidSource()
  let object = UnsafeMutablePointer<ObjectHeader>.allocate(capacity: 1)
  init() {
    object.initialize(to: ObjectHeader(source: source, ownerJob: 1, kind: TarwinKind.event, maximumRights: 128)!)
    for i in 0..<2 { (buckets + i).initialize(to: AddressBucket()); (sleepers + i).initialize(to: AddressSleeper()) }
    queue.initialize(to: AddressQueue(buckets: .init(start: buckets, count: 2),
      sleepers: .init(start: sleepers, count: 2), pageBytes: 4096)!)
    for i in 0..<2 { (objectBuckets + i).initialize(to: AddressBucket()); (objectSleepers + i).initialize(to: AddressSleeper()) }
    objectQueue.initialize(to: AddressQueue(buckets: .init(start: objectBuckets, count: 2),
      sleepers: .init(start: objectSleepers, count: 2), pageBytes: 4096)!)
  }
  func withReadable<R>(_ address: UInt64, width: UInt32, _ body: (Word) -> R) -> R? {
    address == 4096 ? body(Word(context: self)) : nil
  }
  func critical<R>(_ body: () -> R) -> R { body() }
  func monotonic() -> UInt64 { now }
  func owner(of: Word, ifEqualTo: UInt32) -> UInt64 { 0 }
  func change(_ event: AddressChange, deadline: UInt64) {
    if case .ready(let ticket, _, _, let reason) = event { completed.append((ticket, reason)) }
  }
  func park(_ ticket: SleepTicket) -> WaitEnd {
    parked += 1
    let target = objectWaitActive ? objectQueue : queue
    _ = target.pointee.finish(ticket, reason: .woken, change: { change($0, deadline: .max) })
    objectWaitActive = false
    return .woken
  }
  func withWaitObject(name: UInt64, mask: UInt32,
    _ body: (UnsafePointer<ObjectHeader>) -> SplitWaitResult) -> SplitWaitResult {
    guard name == 7 else { return .completed(CallResult(status: syscallStatus(2, 1))) }
    _ = object.pointee.updateSignals(clear: .max, set: UInt32(value))
    let result = body(UnsafePointer(object))
    if case .blocked = result { objectWaitActive = true }
    return result
  }
  func observed(_ ticket: SleepTicket) -> UInt32 { UInt32(value) }
  deinit {
    _ = object.pointee.release(); object.deinitialize(count: 1); object.deallocate()
    queue.deinitialize(count: 1); queue.deallocate()
    sleepers.deinitialize(count: 2); sleepers.deallocate()
    buckets.deinitialize(count: 2); buckets.deallocate()
    objectQueue.deinitialize(count: 1); objectQueue.deallocate()
    objectSleepers.deinitialize(count: 2); objectSleepers.deallocate()
    objectBuckets.deinitialize(count: 2); objectBuckets.deallocate()
  }
}

private final class PairContext: ChannelCreateContext {
  let source = KoidSource()
  let a = UnsafeMutablePointer<ObjectHeader>.allocate(capacity: 1)
  let b = UnsafeMutablePointer<ObjectHeader>.allocate(capacity: 1)
  let cells: UnsafeMutablePointer<HandleCell>
  var table: HandleTable
  var calls = 0
  init(capacity: Int = 4) {
    cells = .allocate(capacity: capacity)
    table = HandleTable(storage: .init(start: cells, count: capacity), salt: 1)!
    a.initialize(to: ObjectHeader(source: source, ownerJob: 1, kind: TarwinKind.channel, maximumRights: 0x7cf)!)
    b.initialize(to: ObjectHeader(source: source, ownerJob: 1, kind: TarwinKind.channel, maximumRights: 0x7cf)!)
    size = capacity
  }
  let size: Int
  func withNewChannel(_ body: (UnsafePointer<ObjectHeader>, UnsafePointer<ObjectHeader>, inout HandleTable) -> CallResult) -> CallResult {
    calls += 1
    return body(UnsafePointer(a), UnsafePointer(b), &table)
  }
  deinit {
    table.drain { _ in }
    cells.deinitialize(count: size); cells.deallocate()
    _ = a.pointee.release(); _ = b.pointee.release()
    a.deinitialize(count: 1); b.deinitialize(count: 1); a.deallocate(); b.deallocate()
  }
}

final class ProviderTests: XCTestCase {
  func testSplitWaitWakeTimeoutCancellationAndStaleTicket() {
    let c = QueueContext()
    let provider = SplitWaitCalls(context: c)
    func arm() -> SleepTicket {
      [UInt64(4096), 0, 100].withUnsafeBufferPointer {
        guard case .blocked(let ticket) = provider.begin(number: TarwinCall.syncWait32, words: $0) else { fatalError() }
        return ticket
      }
    }
    let first = arm()
    XCTAssertEqual(c.parked, 0)
    XCTAssertEqual(c.queue.pointee.wake(.init(frame: 1, offset: 0), count: 1,
      change: { c.change($0, deadline: .max) }), 1)
    XCTAssertEqual(c.completed.first?.0, first)
    XCTAssertEqual(waitCallCompletion(c.completed[0].1).code, 0)
    let second = arm()
    XCTAssertFalse(c.queue.pointee.finish(first, reason: .timeout, change: { _ in XCTFail() }))
    XCTAssertTrue(c.queue.pointee.finish(second, reason: .timeout, change: { c.change($0, deadline: .max) }))
    XCTAssertEqual(waitCallCompletion(c.completed[1].1).code, 25)
    let third = arm()
    XCTAssertTrue(c.queue.pointee.finish(third, reason: .cancelled, change: { c.change($0, deadline: .max) }))
    XCTAssertEqual(waitCallCompletion(c.completed[2].1).code, 26)
  }
  func testSplitValidationAndSynchronousCompatibility() {
    let c = QueueContext()
    func result(_ words: [UInt64]) -> UInt32 {
      words.withUnsafeBufferPointer {
        switch SplitWaitCalls(context: c).begin(number: TarwinCall.syncWait32, words: $0) {
        case .completed(let r): return r.code
        case .blocked: XCTFail(); return .max
        }
      }
    }
    XCTAssertEqual(result([]), 1)
    XCTAssertEqual(result([4097, 0, 100]), 1)
    XCTAssertEqual(result([4096, 1, 100]), 23)
    XCTAssertEqual(result([4096, 0, 1]), 25)
    c.fault = true
    XCTAssertEqual(result([4096, 0, 100]), 1)
    c.fault = false
    let r = [UInt64(4096), 0, 100].withUnsafeBufferPointer {
      WaitCalls(context: c).invoke(number: TarwinCall.syncWait32, words: $0)
    }
    XCTAssertEqual(r.code, 0)
    XCTAssertEqual(c.parked, 1)
  }
  func testObjectWaitImmediateBlockedAndInvalid() {
    let c = QueueContext()
    let calls = ObjectWaitCalls(context: c)
    c.value = 8
    let immediate = [UInt64(7), 8, 100].withUnsafeBufferPointer { calls.begin(number: TarwinCall.objectWait, words: $0) }
    guard case .completed(let r) = immediate else { return XCTFail() }
    XCTAssertEqual(r.first, 8)
    c.value = 0
    let blocked = [UInt64(7), 8, 100].withUnsafeBufferPointer { calls.begin(number: TarwinCall.objectWait, words: $0) }
    guard case .blocked(let ticket) = blocked else { return XCTFail() }
    c.value = 8
    _ = c.park(ticket)
    XCTAssertEqual(calls.complete(ticket, reason: .woken).first, 8)
    for words: [UInt64] in [[], [7, 0, 100], [99, 8, 100]] {
      let out = words.withUnsafeBufferPointer { calls.begin(number: TarwinCall.objectWait, words: $0) }
      guard case .completed(let e) = out else { return XCTFail() }
      XCTAssertNotEqual(e.code, 0)
    }
    c.value = 0
    let synchronous = [UInt64(7), 8, 100].withUnsafeBufferPointer {
      calls.invoke(number: TarwinCall.objectWait, words: $0)
    }
    XCTAssertEqual(synchronous.code, 0)
    XCTAssertEqual(c.parked, 2)
  }
  func testTimeReadAndInvalidOrUnavailableClock() {
    struct Clock: TimeCallClock {
      func read(clock: UInt32) -> UInt64? { clock == 2 ? nil : 42 + UInt64(clock) }
    }
    let calls = TimeCalls(clock: Clock())
    for (words, code): ([UInt64], UInt32) in [([0], 0), ([1], 0), ([2], 23), ([3], 0), ([4], 0), ([5], 1), ([], 1)] {
      let r = words.withUnsafeBufferPointer { calls.invoke(number: TarwinCall.timeRead, words: $0) }
      XCTAssertEqual(r.code, code)
      if code == 0 { XCTAssertEqual(r.first, 42 + words[0]) }
    }
  }
  func testObjectAndAddressWaitKeySpacesAreIndependent() {
    let c = QueueContext()
    let addressWait = [UInt64(4096), 0, 100].withUnsafeBufferPointer {
      SplitWaitCalls(context: c).begin(number: TarwinCall.syncWait32, words: $0)
    }
    guard case .blocked(let addressTicket) = addressWait else { return XCTFail() }
    c.threadSlot = 1
    let objectWait = [UInt64(7), 8, 100].withUnsafeBufferPointer {
      ObjectWaitCalls(context: c).begin(number: TarwinCall.objectWait, words: $0)
    }
    guard case .blocked(let objectTicket) = objectWait else { return XCTFail() }
    XCTAssertEqual(c.object.pointee.koid, 1)
    XCTAssertEqual(c.queue.pointee.wake(.init(frame: 1, offset: 0), count: 2,
      change: { c.change($0, deadline: .max) }), 1)
    XCTAssertEqual(c.completed.count, 1)
    XCTAssertEqual(c.completed[0].0, addressTicket)
    XCTAssertTrue(c.objectQueue.pointee.finish(objectTicket, reason: .cancelled,
      change: { c.change($0, deadline: .max) }))
  }
  func testChannelCreationAndCapacityRollback() {
    let c = PairContext()
    var calls = ChannelCreateCalls(context: c)
    let r = [UInt64(0)].withUnsafeBufferPointer { calls.invoke(number: TarwinCall.channelCreate, words: $0) }
    XCTAssertEqual(r.code, 0)
    XCTAssertNotEqual(r.first, r.second)
    XCTAssertEqual(c.table.count, 2)
    for words: [UInt64] in [[], [1]] {
      let bad = words.withUnsafeBufferPointer { calls.invoke(number: TarwinCall.channelCreate, words: $0) }
      XCTAssertEqual(bad.code, 1)
    }
    let small = PairContext(capacity: 1)
    var limited = ChannelCreateCalls(context: small)
    let out = [UInt64(0)].withUnsafeBufferPointer { limited.invoke(number: TarwinCall.channelCreate, words: $0) }
    XCTAssertEqual(out.code, 33)
    XCTAssertEqual(small.table.count, 0)
  }
}
