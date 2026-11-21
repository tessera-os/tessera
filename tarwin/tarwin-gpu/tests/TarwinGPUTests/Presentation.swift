import TarwinGPU
import TarwinSched
import XCTest

final class PresentationTests: XCTestCase {
  func testOnlyDriverWorkersReceiveTheFrameDeadline() {
    var storage = [UInt64](repeating: 0, count: 2)
    storage.withUnsafeMutableBufferPointer { slab in
      var q = PresentationQueue(
        queue: 10, presenter: 30, driver: 20, slotEpoch: 4,
        referenceCapacity: 1024, members: slab)!
      XCTAssertFalse(q.addWorker(101, owner: 30, epoch: 4))
      XCTAssertFalse(q.addWorker(101, owner: 20, epoch: 3))
      XCTAssertFalse(q.addWorker(0, owner: 20, epoch: 4))
      XCTAssertTrue(q.addWorker(101, owner: 20, epoch: 4))
      XCTAssertFalse(q.addWorker(101, owner: 20, epoch: 4))
      XCTAssertTrue(q.addWorker(102, owner: 20, epoch: 4))
      XCTAssertFalse(q.addWorker(103, owner: 20, epoch: 4))
      XCTAssertNil(q.present(by: 20, epoch: 4, now: 0, deadline: 100))
      XCTAssertNil(q.present(by: 30, epoch: 5, now: 0, deadline: 100))
      XCTAssertNil(q.present(by: 30, epoch: 4, now: 100, deadline: 100))
      let f = q.present(by: 30, epoch: 4, now: 1, deadline: 100)!
      XCTAssertEqual(f.deadline, 100)
      XCTAssertEqual(f.queue, 10)
      XCTAssertEqual(f.slotEpoch, 4)
      XCTAssertNil(q.present(by: 30, epoch: 4, now: 2, deadline: 90))
      XCTAssertFalse(q.charge(f, worker: 103, from: 1, to: 51, capacity: 512))
      XCTAssertTrue(q.charge(f, worker: 101, from: 1, to: 51, capacity: 512))
      XCTAssertFalse(q.complete(f, by: 30, now: 80))
      XCTAssertFalse(q.complete(f, by: 20, now: 50))
      XCTAssertTrue(q.complete(f, by: 20, now: 80))
      XCTAssertFalse(q.complete(f, by: 20, now: 80))
      XCTAssertEqual(q.demand(101, now: 200), 0)
      XCTAssertNil(q.present(by: 30, epoch: 4, now: 75, deadline: 100))
      let second = q.present(by: 30, epoch: 4, now: 100, deadline: 200)!
      XCTAssertNotEqual(f, second)
      XCTAssertFalse(q.charge(f, worker: 101, from: 140, to: 150, capacity: 1024))
      XCTAssertFalse(q.complete(f, by: 20, now: 150))
      XCTAssertEqual(q.demand(101, now: 150), 512)
      XCTAssertEqual(q.demand(102, now: 200), 1024)
      XCTAssertTrue(q.removeWorker(102))
      XCTAssertEqual(q.demand(102, now: 200), 0)
      let points = [point(256), point(512), point(1024, ceiling: 512)]
      points.withUnsafeBufferPointer {
        XCTAssertEqual(
          selectOperatingPoint(
            $0, required: 0, job: 3, qos: SchedClass.interactive,
            demand: q.demand(101, now: 100), haveEfficiency: false), 0)
        XCTAssertEqual(
          selectOperatingPoint(
            $0, required: 0, job: 3, qos: SchedClass.interactive,
            demand: q.demand(101, now: 150), haveEfficiency: false), 1)
        XCTAssertEqual(
          selectOperatingPoint(
            $0, required: 0, job: 3, qos: SchedClass.interactive,
            demand: q.demand(101, now: 200), haveEfficiency: false), 1)
      }
    }
  }

  func testRestartCannotChargeOrFinishAReplacementFrame() {
    var bytes = [UInt64](repeating: 0, count: 1)
    bytes.withUnsafeMutableBufferPointer { slab in
      func open(_ epoch: UInt64) -> PresentationQueue {
        PresentationQueue(
          queue: 1, presenter: 3, driver: 2, slotEpoch: epoch, referenceCapacity: 100, members: slab
        )!
      }
      let old: PresentationFrame
      do {
        var q = open(5)
        XCTAssertTrue(q.addWorker(10, owner: 2, epoch: 5))
        old = q.present(by: 3, epoch: 5, now: 1, deadline: 20)!
        XCTAssertEqual(q.demand(10, now: 20), 100)
        q.disconnect()
        XCTAssertEqual(q.demand(10, now: 20), 0)
        XCTAssertFalse(q.complete(old, by: 2, now: 22))
        XCTAssertFalse(q.charge(old, worker: 10, from: 10, to: 20, capacity: 100))
        XCTAssertNil(q.present(by: 3, epoch: 5, now: 3, deadline: 20))
      }
      var next = open(6)
      XCTAssertTrue(next.addWorker(10, owner: 2, epoch: 6))
      let f = next.present(by: 3, epoch: 6, now: 1, deadline: 20)!
      XCTAssertEqual(old.interval, f.interval)
      XCTAssertFalse(next.complete(old, by: 2, now: 10))
      XCTAssertFalse(next.charge(old, worker: 10, from: 1, to: 10, capacity: 100))
      XCTAssertTrue(next.complete(f, by: 2, now: 10))
    }
  }
}

private func point(_ capacity: UInt32, ceiling: UInt64 = 1024) -> OperatingPoint {
  OperatingPoint(
    offer: CpuOffer(
      online: true, features: 0, capacity: capacity, energy: capacity, load: 0,
      efficiency: true, idle: true, thermalHeadroom: true, runningSiblingJob: 0,
      isolatedSiblings: true),
    hz: UInt64(capacity), ceilingHz: ceiling)
}
