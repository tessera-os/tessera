import XCTest

@testable import TarwinSched

func key(_ qos: UInt8, _ id: UInt64) -> DispatchKey {
  return DispatchKey(
    qos: qos, readySince: 10, virtualStart: 5,
    virtualDeadline: 10, classVirtualTime: 5, absoluteDeadline: 80,
    remainingBudget: 2, threadId: id)
}

final class TarwinSchedTests: XCTestCase {
  func testDomainContracts() {
    XCTAssertEqual(reservationPpb(9, 10, 9), 900_000_000)
    XCTAssertEqual(reservationPpb(1, 3, 1), 333_333_334)
    XCTAssertEqual(
      reservationPpb(
        18_446_744_073_709_551_614, 18_446_744_073_709_551_615, 18_446_744_073_709_551_614),
      1_000_000_000)
    XCTAssertEqual(reservationPpb(0, 0, 0), 0)
    XCTAssertTrue(canAdmit(100_000_000, 800_000_000, 1_000_000_000, 0, 100_000_000, true))
    XCTAssertFalse(canAdmit(100_000_001, 800_000_000, 1_000_000_000, 0, 100_000_001, true))
    XCTAssertFalse(canAdmit(1, 0, 1_000_000_000, 1, 1, true))
    XCTAssertFalse(canAdmit(1, 0, 1_000_000_000, 0, 1, false))
    var budget = PeriodBudget(release: 0, remaining: 2, period: 10, capacity: 2)
    budget.charge(4)
    budget.replenish(9)
    XCTAssertEqual(budget.remaining, 0)
    budget.replenish(25)
    XCTAssertEqual(budget.release, 20)
    XCTAssertEqual(budget.remaining, 2)
    let normal = key(SchedClass.normal, 1)
    let interactive = key(SchedClass.interactive, 2)
    let deadline = key(SchedClass.deadline, 3)
    XCTAssertTrue(dispatchBefore(interactive, normal, 100_000_009))
    XCTAssertTrue(dispatchBefore(normal, interactive, 100_000_010))
    XCTAssertFalse(dispatchBefore(normal, deadline, 100_000_010))
    XCTAssertEqual(virtualSlice(3_000_000, 0), 3_000_000)
    XCTAssertGreaterThan(virtualSlice(3_000_000, -16), virtualSlice(3_000_000, 15))
    let cpu = CpuOffer(
      online: true, features: 5, capacity: 10, energy: 3,
      load: 2, efficiency: false, idle: false, thermalHeadroom: true,
      runningSiblingJob: 7, isolatedSiblings: true)
    XCTAssertTrue(cpuEligible(cpu, 1, 7, SchedClass.interactive, 10, true))
    XCTAssertFalse(cpuEligible(cpu, 2, 7, SchedClass.interactive, 10, true))
    XCTAssertFalse(cpuEligible(cpu, 1, 8, SchedClass.interactive, 10, true))
    XCTAssertFalse(cpuEligible(cpu, 1, 7, SchedClass.background, 10, true))
    XCTAssertFalse(cpuEligible(cpu, 1, 7, SchedClass.utility, 10, true))
    XCTAssertFalse(cpuEligible(cpu, 1, 7, SchedClass.normal, 11, false))
  }
}
