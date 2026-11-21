import TarwinSched
import XCTest

final class BootstrapTests: XCTestCase {
  func testBootWakePreemptBlockAndTicklessIdle() {
    var cpu = BootstrapCPU(now: 0)
    XCTAssertEqual(cpu.select(now: 0), 0)
    XCTAssertTrue(cpu.create(id: 1, qos: SchedClass.normal))
    XCTAssertTrue(cpu.create(id: 2, qos: SchedClass.interactive))
    XCTAssertTrue(cpu.wake(1, now: 0))
    XCTAssertFalse(cpu.wake(1, now: 0))
    XCTAssertEqual(cpu.select(now: 0), 1)
    XCTAssertNil(cpu.nextSliceEnd(now: 0))
    XCTAssertTrue(cpu.wake(2, now: 1_000_000))
    XCTAssertEqual(cpu.select(now: 1_000_000), 2)
    XCTAssertEqual(cpu.nextSliceEnd(now: 2_000_000), 4_000_000)
    XCTAssertTrue(cpu.sleepRunning(now: 3_000_000))
    XCTAssertEqual(cpu.select(now: 3_000_000), 1)
    XCTAssertNil(cpu.nextSliceEnd(now: 3_000_000))
    XCTAssertTrue(cpu.remove(1, now: 3_000_001))
    XCTAssertEqual(cpu.select(now: 3_000_001), 0)
    XCTAssertFalse(cpu.wake(2, now: 2_000_000))
    XCTAssertTrue(cpu.wake(2, now: 3_000_002))
    XCTAssertEqual(cpu.select(now: 3_000_002), 2)
  }

  func testWeightedServiceForContinuouslyRunnablePeers() {
    var cpu = BootstrapCPU(now: 0)
    for (id, priority) in [(1, -1), (2, 15)] {
      XCTAssertTrue(
        cpu.create(id: UInt64(id), qos: SchedClass.normal, priority: priority, slice: 1_000_000))
      XCTAssertTrue(cpu.wake(UInt64(id), now: 0))
    }
    var share = 0
    for tick in 0..<300 {
      let id = cpu.select(now: UInt64(tick) * 1_000_000)
      if id == 2 { share += 1 } else { XCTAssertEqual(id, 1) }
    }
    XCTAssertTrue((199...201).contains(share), "double weight got \(share)/300")
  }

  func testStarvedDefaultGetsAQuantumDespiteInterveningWake() {
    var cpu = BootstrapCPU(now: 0)
    for (id, qos) in [
      (1, SchedClass.normal), (2, SchedClass.interactive), (3, SchedClass.initiated),
    ] {
      XCTAssertTrue(cpu.create(id: UInt64(id), qos: qos))
    }
    XCTAssertTrue(cpu.wake(1, now: 0))
    XCTAssertTrue(cpu.wake(2, now: 0))
    XCTAssertEqual(cpu.select(now: 0), 2)
    XCTAssertEqual(cpu.select(now: 100_000_000), 1)
    XCTAssertTrue(cpu.wake(3, now: 101_000_000))
    XCTAssertEqual(cpu.select(now: 101_000_000), 1)
    XCTAssertEqual(cpu.select(now: 103_000_000), 2)
  }

  func testCapacityIsAnExplicitBootLimitAndSlotsRecycle() {
    var cpu = BootstrapCPU(now: 0)
    XCTAssertFalse(cpu.create(id: 0, qos: SchedClass.normal))
    XCTAssertFalse(cpu.create(id: 1, qos: SchedClass.deadline))
    for i in 1...64 { XCTAssertTrue(cpu.create(id: UInt64(i), qos: SchedClass.normal)) }
    XCTAssertFalse(cpu.create(id: 65, qos: SchedClass.normal))
    XCTAssertTrue(cpu.remove(1, now: 0))
    XCTAssertTrue(cpu.create(id: 65, qos: SchedClass.normal))
  }
}
