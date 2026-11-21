import Synchronization
import TarwinGPU
import TarwinObject
import TarwinSyscall
import XCTest

private struct Scheduler: FenceScheduler {
  let word: UnsafeMutablePointer<Atomic<UInt64>>
  var parked: [FenceTicket] = [], completed: [FenceTicket] = [], values: [UInt64] = [],
    boost: UInt32 = 0
  var outcomes: [FenceWake] = []
  mutating func park(_ ticket: FenceTicket) { parked.append(ticket) }
  mutating func wake(_ ticket: FenceTicket, _ reason: FenceWake) {
    XCTAssertTrue(parked.contains(ticket))
    XCTAssertFalse(completed.contains(ticket))
    completed.append(ticket)
    outcomes.append(reason)
    values.append(word.pointee.load(ordering: .acquiring))
  }
  mutating func donate(fence: UInt64, priority: UInt32) { boost = priority }
}
private func named(_ result: HandleMutation) -> UInt64 {
  guard case .installed(let name) = result else {
    XCTFail("install failed")
    return 0
  }
  return name
}
final class FenceObjectTests: XCTestCase {
  func testTransferredWaitRightsUseSameTimelineAndHoldReferenceUntilTerminalWake() {
    let ids = KoidSource()
    func object(_ kind: UInt32, _ rights: UInt64) -> UnsafeMutablePointer<ObjectHeader> {
      let h = UnsafeMutablePointer<ObjectHeader>.allocate(capacity: 1)
      h.initialize(to: ObjectHeader(source: ids, ownerJob: 2, kind: kind, maximumRights: rights)!)
      return h
    }
    let h = object(TarwinKind.fence, 255)
    let other = object(TarwinKind.fence, 255)
    let presence = object(TarwinKind.presence, 128)
    let s = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 4)
    let d = UnsafeMutableBufferPointer<HandleCell>.allocate(capacity: 2)
    var driver = HandleTable(storage: s, salt: 17)!
    var client = HandleTable(storage: d, salt: 18)!
    let waits = UnsafeMutableBufferPointer<FenceWait>.allocate(capacity: 2)
    waits.initialize(repeating: FenceWait(key: 0, target: 0, priority: 0))
    let output = UnsafeMutablePointer<Atomic<UInt64>>.allocate(capacity: 1)
    output.initialize(to: Atomic(0))
    defer {
      driver.drain { _ in XCTFail() }
      client.drain { _ in XCTFail() }
      for p in [other, presence] { XCTAssertEqual(p.pointee.release(), .destroy) }
      for p in [h, other, presence] {
        p.deinitialize(count: 1)
        p.deallocate()
      }
      s.deinitialize()
      s.deallocate()
      d.deinitialize()
      d.deallocate()
      waits.deinitialize()
      waits.deallocate()
      output.deinitialize(count: 1)
      output.deallocate()
    }
    var fence = FenceObject(header: h, word: output, waiters: waits)!
    var scheduler = Scheduler(word: output)
    let sig = named(driver.install(h, rights: 195))
    let export = named(driver.derive(sig, rights: 130, duplicate: true))
    var wait: UInt64 = 0
    [export].withUnsafeBufferPointer { names in
      XCTAssertEqual(
        driver.moveForChannel(names) { (g: consuming ObjectGrant) in
          switch client.installMoved(g) {
          case .installed(let name): wait = name
          case .limit(let g):
            g.drop { _ in XCTFail() }
            XCTFail()
          }
        }, .allowed)
    }
    var retired = 0
    let retire: (UnsafePointer<ObjectHeader>) -> Void = { p in
      XCTAssertEqual(p, UnsafePointer(h))
      retired += 1
    }
    let w = TarwinCall.fenceWait
    let signal = TarwinCall.fenceSignal
    func call(_ op: UInt64, _ name: UInt64, _ v: UInt64, _ table: HandleReadView, _ qos: UInt32 = 0)
      -> FenceReply
    {
      fence.invoke(
        number: op, name: name, value: v, priority: qos, table: table, scheduler: &scheduler,
        retire: retire)
    }
    XCTAssertEqual(call(w, export, 1, driver.reader), .invalidHandle)
    XCTAssertEqual(call(signal, wait, 9, client.reader), .denied)
    let wrong = named(driver.install(other, rights: 128))
    let notFence = named(driver.install(presence, rights: 128))
    XCTAssertEqual(call(w, wrong, 1, driver.reader), .invalidHandle)
    XCTAssertEqual(call(w, notFence, 1, driver.reader), .wrongType)
    XCTAssertEqual(call(TarwinCall.interruptComplete, sig, 1, driver.reader), .unsupported)
    XCTAssertEqual(call(w, wait, 0, client.reader), .ready)
    guard case .parked(let a) = call(w, wait, 9, client.reader, 4),
      case .parked(let b) = call(w, wait, 5, client.reader, 6)
    else { return XCTFail("wait not parked") }
    XCTAssertEqual(call(w, wait, 20, client.reader, 9), .full)
    XCTAssertEqual(scheduler.boost, 6)
    XCTAssertEqual(call(signal, sig, 5, driver.reader), .ready)
    XCTAssertEqual(scheduler.completed, [b])
    XCTAssertEqual(scheduler.values, [5])
    XCTAssertEqual(scheduler.boost, 4)
    XCTAssertEqual(call(signal, sig, 4, driver.reader), .invalidValue)
    XCTAssertFalse(fence.cancel(b, scheduler: &scheduler, retire: retire))
    XCTAssertTrue(fence.cancel(a, scheduler: &scheduler, retire: retire))
    XCTAssertEqual(scheduler.boost, 0)
    guard case .parked(let c) = call(w, wait, 10, client.reader, 5) else {
      return XCTFail("wait not parked")
    }
    XCTAssertNotEqual(c, a)
    XCTAssertFalse(fence.cancel(a, scheduler: &scheduler, retire: retire))
    XCTAssertTrue(client.close(wait, retire: retire))
    XCTAssertTrue(driver.close(sig, retire: retire))
    XCTAssertEqual(h.pointee.release(), .stillLive)
    XCTAssertEqual(retired, 0)
    // Teardown takes its own lifetime pin while holding the payload lock.
    XCTAssertTrue(h.pointee.retainIfLive())
    fence.disconnect(scheduler: &scheduler, retire: retire)
    let detached = named(driver.install(h, rights: 128))
    XCTAssertEqual(call(w, detached, 1, driver.reader), .deviceRemoved)
    XCTAssertTrue(driver.close(detached, retire: retire))
    fence.disconnect(scheduler: &scheduler, retire: retire)
    XCTAssertEqual(retired, 0)
    XCTAssertEqual(h.pointee.release(), .destroy)
    XCTAssertFalse(h.pointee.retainIfLive())
    XCTAssertEqual(scheduler.completed, [b, a, c])
    XCTAssertEqual(scheduler.outcomes, [.signaled, .cancelled, .deviceRemoved])
    XCTAssertEqual(scheduler.values, [5, 5, 5])
    XCTAssertEqual(scheduler.boost, 0)
  }
}
