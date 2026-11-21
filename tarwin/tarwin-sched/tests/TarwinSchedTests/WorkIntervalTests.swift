import TarwinSched
import XCTest

final class WorkIntervalTests: XCTestCase {
  func testOperatingPointCannotOverrideCeilingOrIsolation() {
    func point(
      _ capacity: UInt32, _ energy: UInt32, _ hz: UInt64, _ maxHz: UInt64,
      sibling: UInt64 = 7, features: UInt64 = 3, efficient: Bool = false
    ) -> OperatingPoint {
      .init(
        offer: .init(
          online: true, features: features, capacity: capacity, energy: energy,
          load: 0, efficiency: efficient, idle: true, thermalHeadroom: true,
          runningSiblingJob: sibling,
          isolatedSiblings: true), hz: hz, ceilingHz: maxHz)
    }
    let points = [
      point(10, 1, 10, 10, efficient: true), point(40, 3, 40, 80), point(80, 7, 80, 80),
      point(90, 2, 90, 80), point(100, 1, 100, 100, sibling: 9),
      point(100, 1, 100, 100, features: 1),
    ]
    func pick(_ demand: UInt32, _ qos: UInt8 = SchedClass.interactive) -> Int? {
      points.withUnsafeBufferPointer {
        selectOperatingPoint(
          $0, required: 3, job: 7, qos: qos, demand: demand, haveEfficiency: true)
      }
    }
    XCTAssertEqual(pick(10), 0)
    XCTAssertEqual(pick(35), 1)
    XCTAssertEqual(pick(70), 2)
    XCTAssertEqual(pick(100), 2)
    XCTAssertEqual(pick(100, SchedClass.background), 0)
    XCTAssertNil(pick(0, SchedClass.idle))
  }

  func testHistoryPlacementAndLateCallbacks() {
    var slots = [UInt64](repeating: .max, count: 2)
    slots.withUnsafeMutableBufferPointer { b in
      guard var group = WorkInterval(owner: 1, referenceCapacity: 100, members: b) else {
        return XCTFail()
      }
      XCTAssertFalse(group.join(3, by: 3))
      XCTAssertTrue(group.join(3, by: 1))
      XCTAssertTrue(group.join(4, by: 1))
      XCTAssertFalse(group.join(5, by: 1))
      XCTAssertFalse(group.join(3, by: 1))
      XCTAssertNil(group.begin(by: 3, start: 1, deadline: 20))
      guard let a = group.begin(by: 1, start: 0, deadline: 100) else { return XCTFail() }
      XCTAssertFalse(group.charge(0, epoch: a, from: 0, to: 50, capacity: 100))
      XCTAssertTrue(group.charge(3, epoch: a, from: 0, to: 40, capacity: 50))
      XCTAssertTrue(group.charge(4, epoch: a, from: 0, to: 30, capacity: 100))
      XCTAssertFalse(group.complete(by: 1, epoch: a, now: 39))
      XCTAssertTrue(group.complete(by: 1, epoch: a, now: 40))
      XCTAssertNil(group.begin(by: 1, start: 20, deadline: 60))
      guard let b = group.begin(by: 1, start: 100, deadline: 200) else { return XCTFail() }
      XCTAssertFalse(group.complete(by: 1, epoch: a, now: 150))
      XCTAssertFalse(group.charge(3, epoch: a, from: 100, to: 150, capacity: 100))
      XCTAssertEqual(group.demand(3, now: 99), 0)
      XCTAssertEqual(group.demand(3, now: 100), 50)
      XCTAssertTrue(group.charge(3, epoch: b, from: 100, to: 120, capacity: 100))
      XCTAssertEqual(group.demand(4, now: 150), 60)
      XCTAssertEqual(group.demand(4, now: 171), 100)
      XCTAssertTrue(group.leave(4))
      XCTAssertEqual(group.demand(4, now: 201), 0)
      XCTAssertEqual(group.demand(3, now: 201), 100)
      XCTAssertTrue(group.complete(by: 1, epoch: b, now: 202))
      XCTAssertEqual(group.demand(3, now: 202), 0)
      guard group.begin(by: 1, start: 202, deadline: 302) != nil else { return XCTFail() }
      XCTAssertEqual(group.demand(3, now: 202), 43)
    }
  }
}
