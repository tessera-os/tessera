import XCTest

@testable import TarwinNet

final class InterfaceTxTests: XCTestCase {
  func testRestartKeepsPinsAndPacingButNeverReplaysPublishedDatagrams() {
    withUnsafeTemporaryAllocation(of: TxSlot.self, capacity: 4) { slots in
      withUnsafeTemporaryAllocation(of: TxFlow.self, capacity: 3) { flows in
        slots.initialize(repeating: TxSlot())
        flows.initialize(repeating: TxFlow())
        defer {
          slots.deinitialize()
          flows.deinitialize()
        }
        var q = InterfaceTxQueue(packets: slots, flows: flows)
        let allow: (UInt64, UInt64) -> Bool = { $0 == 1 && $1 != 0 }
        var pins = Set<UInt64>()
        var done = [UInt64: TxDisposition]()
        let pin: (UInt64, UInt64, UInt64, UInt32) -> UInt64 = { _, m, _, _ in
          pins.insert(m)
          return m
        }
        let finish: (UInt64, UInt64, TxDisposition) -> Void = { id, m, result in
          XCTAssertNotNil(pins.remove(m))
          done[id] = result
        }
        func p(_ f: UInt64, _ m: UInt64, _ time: UInt64, _ bg: Bool) -> TxPacket {
          TxPacket(
            process: 1, flow: f, memory: m, offset: 0, bytes: 100, notBefore: time, background: bg)
        }
        let background = q.enqueue(p(2, 51, 0, true), allowed: allow, pin: pin)
        let first = q.enqueue(p(1, 52, 10, false), allowed: allow, pin: pin)
        let next = q.enqueue(p(1, 53, 0, false), allowed: allow, pin: pin)
        XCTAssertTrue(q.dispatch(now: 9, congested: true) { _, id, _, _ in id == background })
        XCTAssertFalse(q.dispatch(now: 10, congested: true) { _, _, _, _ in false })
        XCTAssertTrue(q.dispatch(now: 10, congested: true) { _, id, _, _ in id == first })
        q.stop()
        XCTAssertFalse(q.recover(removed: false, drainOldDomain: { false }, retire: finish))
        XCTAssertEqual(pins.count, 3)
        XCTAssertTrue(q.recover(removed: false, drainOldDomain: { true }, retire: finish))
        XCTAssertEqual(done[first], .inFlightLost)
        XCTAssertEqual(done[background], .inFlightLost)
        XCTAssertFalse(q.complete(epoch: 1, key: next, retire: finish))
        XCTAssertTrue(
          q.dispatch(now: 10, congested: false) { epoch, id, m, _ in
            epoch == 2 && id == next && m == 53
          })
        XCTAssertTrue(q.complete(epoch: 2, key: next, retire: finish))
        XCTAssertTrue(pins.isEmpty)
        let removed = q.enqueue(p(1, 54, 0, false), allowed: allow, pin: pin)
        q.stop()
        XCTAssertTrue(q.recover(removed: true, drainOldDomain: { true }, retire: finish))
        XCTAssertEqual(done[removed], .deviceRemoved)
        XCTAssertTrue(pins.isEmpty)
        XCTAssertEqual(q.enqueue(p(1, 55, 0, false), allowed: allow, pin: pin), 0)
      }
    }
  }
}
