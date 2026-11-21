import TarwinPower
import XCTest

final class ThermalTests: XCTestCase {
  let limits = ClusterThermalLimits(
    nominalHz: 3000, fairHz: 2500, seriousHz: 1800, criticalHz: 1000, windowNs: 100,
    utilityBackgroundNs: 20, nonInteractiveNs: 45)!
  func z(_ t: Int) -> ThermalZone {
    ThermalZone(millidegrees: t, fair: 50, serious: 65, critical: 80)
  }
  func testHardwareCapPrecedesBudgetAndSkinAppliesWhileDocked() {
    var g = ClusterGovernor(limits: limits, now: 0)
    XCTAssertEqual(g.reserve(.deadline, now: 0, wanted: 4), 0)
    XCTAssertTrue(g.refresh(zones: [z(50)], skin: z(0), handheld: true, fresh: true) { $0 == 2500 })
    XCTAssertEqual(g.reserve(.background, now: 3, wanted: 12), 12)
    XCTAssertTrue(
      g.refresh(zones: [z(20)], skin: z(65), handheld: true, fresh: true) { $0 == 1800 })
    XCTAssertEqual(g.reserve(.utility, now: 5, wanted: 88), 8)
    XCTAssertEqual(g.reserve(.background, now: 5, wanted: 88), 0)
    XCTAssertTrue(
      g.refresh(zones: [z(20)], skin: z(90), handheld: true, fresh: true) { $0 == 1000 })
    XCTAssertEqual(g.reserve(.initiated, now: 5, wanted: 80), 25)
    XCTAssertEqual(g.reserve(.standard, now: 6, wanted: 80), 0)
    XCTAssertEqual(g.reserve(.interactive, now: 6, wanted: 1000), 94)
    XCTAssertEqual(g.reserve(.deadline, now: 2, wanted: 100), 0)
    XCTAssertEqual(g.reserve(.background, now: 105, wanted: 100), 20)
    XCTAssertEqual(g.reserve(.initiated, now: 299, wanted: 100), 1)
  }
  func testMissingOrStaleMeasurementsAndActuatorFailure() {
    var g = ClusterGovernor(limits: limits, now: 0)
    XCTAssertFalse(g.refresh(zones: [z(0)], skin: nil, handheld: true, fresh: true) { _ in false })
    XCTAssertEqual(g.maximumHz, 0)
    XCTAssertEqual(g.reserve(.interactive, now: 0, wanted: 1), 0)
    XCTAssertTrue(g.refresh(zones: [z(0)], skin: nil, handheld: false, fresh: false) { $0 == 1000 })
    XCTAssertEqual(g.reserve(.deadline, now: .max - 2, wanted: 99), 2)
    XCTAssertEqual(g.reserve(.deadline, now: .max, wanted: 1), 0)
  }
}
