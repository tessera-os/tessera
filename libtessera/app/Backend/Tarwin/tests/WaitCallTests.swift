import Dispatch
import Foundation
import LibTesseraTarwin
import TarwinABI
import TarwinSync
import TarwinSyncCalls
import TarwinSyscall
import XCTest

private struct Word: PinnedWaitWord {
  let physical: WaitAddress, value: UInt64?
  func load() -> UInt64? { value }
}

// The queue manages its locks; the condition models the scheduler's separate
// park/ready handshake and deliberately permits wake before park.
private final class WaitFixture: @unchecked Sendable {
  let buckets: UnsafeMutableBufferPointer<AddressBucket>
  let sleepers = UnsafeMutableBufferPointer<AddressSleeper>.allocate(capacity: 8)
  let queue = UnsafeMutablePointer<AddressQueue>.allocate(capacity: 1)
  private let condition = NSCondition()
  private var tickets: [Int: SleepTicket] = [:], done: [Int: WaitEnd] = [:]
  private var order: [Int] = [], owners: [Int: UInt64] = [:]
  init(buckets n: Int) {
    buckets = .allocate(capacity: n)
    for i in buckets.indices { (buckets.baseAddress! + i).initialize(to: AddressBucket()) }
    for i in sleepers.indices { (sleepers.baseAddress! + i).initialize(to: AddressSleeper()) }
    queue.initialize(to: AddressQueue(buckets: buckets, sleepers: sleepers, pageBytes: 4096)!)
  }
  deinit {
    queue.deinitialize(count: 1)
    queue.deallocate()
    sleepers.deinitialize()
    sleepers.deallocate()
    buckets.deinitialize()
    buckets.deallocate()
  }
  func change(_ event: AddressChange) {
    condition.lock()
    defer {
      condition.broadcast()
      condition.unlock()
    }
    switch event {
    case .block(let t, _, let owner):
      XCTAssertNil(tickets.updateValue(t, forKey: t.slot))
      owners[t.slot] = owner
    case .move(let t, _, _, let old, let new):
      XCTAssertEqual(tickets[t.slot], t)
      XCTAssertEqual(owners[t.slot], old)
      owners[t.slot] = new
    case .ready(let t, _, let owner, let result):
      XCTAssertEqual(tickets.removeValue(forKey: t.slot), t)
      XCTAssertEqual(owners.removeValue(forKey: t.slot), owner)
      done[t.slot] = result
      order.append(t.slot)
    }
  }
  func armed(_ slot: Int) -> SleepTicket? {
    condition.lock()
    defer { condition.unlock() }
    let limit = Date(timeIntervalSinceNow: 3)
    while tickets[slot] == nil { if !condition.wait(until: limit) { return nil } }
    return tickets[slot]
  }
  func park(_ t: SleepTicket) -> WaitEnd {
    condition.lock()
    defer { condition.unlock() }
    let limit = Date(timeIntervalSinceNow: 5)
    while done[t.slot] == nil {
      if !condition.wait(until: limit) {
        XCTFail("wake lost")
        return .timeout
      }
    }
    return done.removeValue(forKey: t.slot)!
  }
  func readyOrder() -> [Int] {
    condition.lock()
    defer { condition.unlock() }
    return order
  }
}

private struct WaitContext: WaitCallContext {
  let fixture: WaitFixture, threadSlot: Int, base: UInt64
  var waits: UnsafePointer<AddressQueue> { UnsafePointer(fixture.queue) }
  func withReadable<R>(_ address: UInt64, width: UInt32, _ body: (Word) -> R) -> R? {
    guard address >= base, address - base <= 16 else { return nil }
    let off = UInt32(address - base)
    return body(
      Word(
        physical: WaitAddress(frame: 77, offset: off),
        value: off == 16 ? nil : (width == 8 ? 0x1_0000_0007 : 7)))
  }
  func monotonic() -> UInt64 { 123 }
  func critical<R>(_ body: () -> R) -> R { body() }
  func owner(of: Word, ifEqualTo: UInt32) -> UInt64 { ifEqualTo == 7 ? 7 : 0 }
  func change(_ event: AddressChange, deadline: UInt64) { fixture.change(event) }
  func park(_ t: SleepTicket) -> WaitEnd { fixture.park(t) }
}

private struct SyncGate: NativeGate {
  let isa: CallISA
  var calls: WaitCalls<WaitContext>
  init(_ f: WaitFixture, slot: Int, base: UInt64, isa: CallISA = .x64) {
    self.isa = isa
    calls = .init(context: .init(fixture: f, threadSlot: slot, base: base))
  }
  mutating func enter(number: UInt64, registers: CallRegisters) -> CallResult {
    var scratch = [UInt64](repeating: 0, count: 4)
    let d = scratch.withUnsafeMutableBufferPointer {
      dispatchCall(
        isa: isa, savedPC: isa == .rv64 ? 4096 : 4096 + isa.instructionWidth,
        libraryCode: 4096..<8192, userRange: 4096..<UInt64.max, number: number,
        registers: registers, scratch: $0, provider: &calls)
    }
    guard case .returned(let r) = d else {
      XCTFail()
      return CallResult(status: .max)
    }
    return r
  }
}

final class WaitCallTests: XCTestCase {
  func testSharedMappingsRequeueFifoAndLateTimeout() throws {
    for bucketCount in [1, 64] {
      let f = WaitFixture(buckets: bucketCount)
      let workers = DispatchGroup()
      var g = SyncGate(f, slot: 7, base: 0x9000)
      var stale: SleepTicket?
      for slot in 0..<4 {
        DispatchQueue.global().async(group: workers) {
          var caller = SyncGate(
            f, slot: slot, base: 0x4000, isa: slot.isMultiple(of: 2) ? .aarch64 : .rv64)
          let r =
            slot == 2
            ? NativeSync.wait64(0x4000, expected: 0x1_0000_0007, deadline: .max, gate: &caller)
            : NativeSync.wait32(
              slot == 0 ? 0x4008 : 0x4000, expected: 7, deadline: .max, gate: &caller)
          XCTAssertEqual(r.code, slot == 2 ? 25 : 0)
        }
        let t = try XCTUnwrap(f.armed(slot))
        if slot == 2 { stale = t }
      }
      XCTAssertEqual(
        NativeSync.requeue(0x9000, wake: 1, target: 0x9008, move: .max, gate: &g).first, 3)
      XCTAssertEqual(NativeSync.wake(0x9000, count: .max, gate: &g).first, 0)
      XCTAssertTrue(f.queue.pointee.finish(stale!, reason: .timeout, change: f.change))
      XCTAssertEqual(NativeSync.wake(0x9008, count: .max, gate: &g).first, 2)
      XCTAssertEqual(workers.wait(timeout: .now() + 4), .success)
      XCTAssertEqual(f.readyOrder(), [1, 2, 0, 3])

      DispatchQueue.global().async(group: workers) {
        var again = SyncGate(f, slot: 2, base: 0x4000)
        XCTAssertEqual(
          NativeSync.wait32(0x4000, expected: 7, deadline: .max, gate: &again).code, 26)
      }
      let fresh = try XCTUnwrap(f.armed(2))
      XCTAssertFalse(f.queue.pointee.finish(stale!, reason: .timeout, change: f.change))
      XCTAssertTrue(f.queue.pointee.finish(fresh, reason: .cancelled, change: f.change))
      XCTAssertEqual(workers.wait(timeout: .now() + 4), .success)
    }
  }
  func testRejectedWordsNeverSleep() {
    let f = WaitFixture(buckets: 2)
    var g = SyncGate(f, slot: 0, base: 0x4000)
    XCTAssertEqual(NativeSync.wait64(0x4004, expected: 7, deadline: .max, gate: &g).code, 1)
    XCTAssertEqual(NativeSync.wait32(0x5000, expected: 7, deadline: .max, gate: &g).code, 1)
    XCTAssertEqual(NativeSync.wait32(0x4010, expected: 7, deadline: .max, gate: &g).code, 1)
    XCTAssertEqual(NativeSync.wait32(0x4000, expected: 8, deadline: .max, gate: &g).code, 23)
    XCTAssertEqual(NativeSync.wait32(0x4000, expected: 7, deadline: 123, gate: &g).code, 25)
    XCTAssertEqual(NativeSync.requeue(0x4000, wake: 1, target: 0x4000, move: 1, gate: &g).code, 1)
    XCTAssertEqual(NativeSync.wake(0x4000, count: .max, gate: &g).first, 0)
  }
}
