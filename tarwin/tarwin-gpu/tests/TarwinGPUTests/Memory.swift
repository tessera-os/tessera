import XCTest

@testable import TarwinGPU

final class MemoryTests: XCTestCase {
  func testClientChargeRemainsUntilItsGpuAllocationIsRetired() {
    var ledger = GpuFootprint(process: 7, limit: 4096, objectLimit: 4)
    let a = GpuCharge(id: 1, bytes: 4096, backing: .deviceLocal)
    XCTAssertTrue(!ledger.charge(8, a))
    XCTAssertTrue(ledger.charge(7, a))
    XCTAssertTrue(!ledger.charge(7, a))
    XCTAssertTrue(!ledger.charge(7, GpuCharge(id: 2, bytes: 1, backing: .system)))
    XCTAssertTrue(!ledger.release(7, 1, { id in return false }))
    XCTAssertTrue(ledger.used == 4096)
    XCTAssertTrue(ledger.release(7, 1, { id in return true }))
    XCTAssertTrue(ledger.used == 0 && ledger.count == 0)
  }
}
