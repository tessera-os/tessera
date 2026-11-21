import XCTest

@testable import TarwinPower

final class PlaneTests: XCTestCase {
  func testCycleOrUnknownProviderSuspendsNothing() {
    let cycle = [PowerEdge(dependent: 0, provider: 1), PowerEdge(dependent: 1, provider: 0)]
    XCTAssertTrue(planSuspend(2, cycle) == SuspendPlan.invalid)
    XCTAssertTrue(planSuspend(1, cycle) == SuspendPlan.invalid)
  }

  func testFailedSuspendRollsBackAndRetryResumesProvidersFirst() {
    let edges = [PowerEdge(dependent: 2, provider: 1), PowerEdge(dependent: 1, provider: 0)]
    switch planSuspend(3, edges) {
    case .invalid: XCTAssertTrue(false)
    case .order(let order):
      var s = SleepTransaction(order: order)
      var log: Int = 0
      let sleep: (Int) -> Bool = { n in
        log = log * 10 + n + 1
        return n != 0
      }
      XCTAssertTrue(!s.quiesce(sleep, { return false }, { n in return false }))
      XCTAssertTrue(s.asleep == 2 && log == 321)
      XCTAssertTrue(
        s.restore({ n in
          log = log * 10 + n + 1
          return true
        }))
      XCTAssertTrue(s.asleep == 0 && log == 32123)
    }
  }

  func testAccountsFractionalCpuSlicesAndHottestZone() {
    var energy = ProcessEnergy()
    for t in 0..<10 { energy.addCpu(100_000_000, 1) }
    XCTAssertTrue(energy.microjoules == 1 && energy.fraction == 0)
    energy.addDevice(8)
    XCTAssertTrue(energy.microjoules == 9)
    energy.addCpu(0xffff_ffff_ffff_ffff, 0xffff_ffff)
    XCTAssertTrue(energy.microjoules == 0xffff_ffff_ffff_ffff)
    let zones = [
      ThermalZone(millidegrees: 70, fair: 50, serious: 60, critical: 80),
      ThermalZone(millidegrees: 50, fair: 50, serious: 60, critical: 80),
    ]
    XCTAssertTrue(thermalBand(zones) == ThermalBand.serious)
  }
}
