import TarwinSched
import XCTest

final class BootstrapTests: XCTestCase {
  func testDirectSwitchPreservesCallerSliceAndRevokesWhilePreempted() throws {
    var cpu = BootstrapCPU(now: 0, identity: 7)
    for (id, qos) in [
      (1, SchedClass.normal), (2, SchedClass.background),
      (3, SchedClass.interactive),
    ] {
      XCTAssertTrue(cpu.create(id: UInt64(id), qos: qos, slice: 1_000_000))
    }
    XCTAssertTrue(cpu.wake(2, now: 0))
    XCTAssertEqual(cpu.select(now: 0), 2)
    let wait = try XCTUnwrap(cpu.waitForService(10, now: 0))
    XCTAssertFalse(cpu.wake(2, now: 0))
    XCTAssertTrue(cpu.wake(1, now: 0))
    XCTAssertEqual(cpu.select(now: 0), 1)
    XCTAssertNil(
      cpu.call(11, waiting: wait, now: 100) {
        XCTFail()
        return true
      })
    XCTAssertNil(cpu.call(10, waiting: wait, now: 100) { false })
    let loan = try XCTUnwrap(cpu.call(10, waiting: wait, now: 100) { true })
    XCTAssertEqual(cpu.running, 2)
    XCTAssertEqual(cpu.charging, 1)
    XCTAssertFalse(cpu.sleepRunning(now: 101))
    XCTAssertFalse(cpu.remove(1, now: 101))
    XCTAssertFalse(cpu.remove(2, now: 101))
    XCTAssertTrue(cpu.wake(3, now: 200))
    XCTAssertEqual(cpu.nextSliceEnd(now: 200), 1_000_000)
    XCTAssertEqual(cpu.select(now: 200), 3)
    XCTAssertFalse(
      cpu.reply(loan, now: 201) {
        XCTFail()
        return true
      })
    XCTAssertTrue(cpu.revoke(loan, now: 202))
    XCTAssertEqual(cpu.running, 3)
    XCTAssertFalse(cpu.revoke(loan, now: 202))
    XCTAssertTrue(cpu.sleepRunning(now: 202))
    XCTAssertEqual(cpu.select(now: 202), 1)
    XCTAssertEqual(cpu.nextSliceEnd(now: 202), 1_000_002)
    XCTAssertFalse(
      cpu.reply(loan, now: 203) {
        XCTFail()
        return true
      })
    XCTAssertNil(
      cpu.call(10, waiting: wait, now: 203) {
        XCTFail()
        return true
      })
  }

  func testReceiverCannotCrossCPUOrLaterReceive() throws {
    func ready(_ id: UInt64) -> BootstrapCPU {
      var cpu = BootstrapCPU(now: 0, identity: id)
      for thread: UInt64 in [1, 2] {
        XCTAssertTrue(cpu.create(id: thread, qos: SchedClass.normal))
        XCTAssertTrue(cpu.wake(thread, now: 0))
      }
      XCTAssertEqual(cpu.select(now: 0), 1)
      return cpu
    }
    var a = ready(41)
    var b = ready(42)
    let old = try XCTUnwrap(a.waitForService(7, now: 0))
    let wrongCPU = try XCTUnwrap(b.waitForService(7, now: 0))
    XCTAssertEqual(a.select(now: 0), 2)
    XCTAssertNil(
      a.call(7, waiting: wrongCPU, now: 0) {
        XCTFail()
        return true
      })
    XCTAssertTrue(a.withdraw(old, now: 0))
    XCTAssertTrue(a.sleepRunning(now: 0))
    XCTAssertEqual(a.select(now: 0), 1)
    let fresh = try XCTUnwrap(a.waitForService(7, now: 0))
    XCTAssertTrue(a.wake(2, now: 0))
    XCTAssertEqual(a.select(now: 0), 2)
    XCTAssertFalse(a.withdraw(old, now: 0))
    XCTAssertNil(
      a.call(7, waiting: old, now: 0) {
        XCTFail()
        return true
      })
    let loan = try XCTUnwrap(a.call(7, waiting: fresh, now: 0) { true })
    XCTAssertFalse(a.reply(loan, now: 0) { false })
    XCTAssertEqual(a.running, 1)
    XCTAssertTrue(a.reply(loan, now: 0) { true })
    XCTAssertEqual(a.running, 2)
    XCTAssertFalse(
      a.reply(loan, now: 0) {
        XCTFail()
        return true
      })
  }
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
