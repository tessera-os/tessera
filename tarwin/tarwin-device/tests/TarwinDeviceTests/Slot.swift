import XCTest

@testable import TarwinDevice

final class SlotTests: XCTestCase {
  func testWholeGroupRemainsUnavailableUntilResetAndDrainComplete() {
    var s = DeviceSlotState(group: 3)
    let isolated: (UInt64, UInt64) -> Bool = { group, epoch in return group == 3 }
    let yes: () -> Bool = { return true }
    let no: () -> Bool = { return false }
    XCTAssertTrue(!s.assign(false, 4, isolated))
    XCTAssertTrue(!s.assign(true, 4, { g, e in return false }))
    XCTAssertTrue(s.assign(true, 4, isolated))
    XCTAssertTrue(s.owns(4, 1))
    XCTAssertTrue(!s.revoke(false, yes, yes, no, yes))
    XCTAssertTrue(!s.owns(4, 1))
    XCTAssertTrue(!s.assign(true, 5, isolated))
    XCTAssertTrue(!s.revoke(false, no, no, yes, no))
    XCTAssertTrue(s.revoke(false, no, no, no, yes))
    XCTAssertTrue(s.assign(true, 5, isolated))
    XCTAssertTrue(s.owns(5, 2))
    XCTAssertTrue(!s.owns(4, 1))
    XCTAssertTrue(s.revoke(true, yes, yes, yes, no))
    XCTAssertTrue(!s.assign(true, 5, isolated))
  }

  func testRegisterMappingCannotCoverAdjacentPagesOrChangeCacheType() {
    var s = DeviceSlotState(group: 7)
    XCTAssertTrue(s.assign(true, 4, { g, e in return true }))
    let page = DeviceRange(base: 0x4000, length: 0x4000)
    let r = MmioAperture(range: page, frameBuffer: false)
    let map: (UInt64, UInt64, UInt64, DeviceCache) -> Bool = { p, a, n, c in
      return p == 4 && a == 0x4000
    }
    XCTAssertTrue(mapSlotRegisters(s, 4, 1, r, page, 0x4000, .register, map))
    XCTAssertTrue(!mapSlotRegisters(s, 4, 2, r, page, 0x4000, .register, map))
    XCTAssertTrue(!mapSlotRegisters(s, 4, 1, r, page, 0x4000, .frameBuffer, map))
    XCTAssertTrue(
      !mapSlotRegisters(s, 4, 1, r, DeviceRange(base: 0, length: 0x8000), 0x4000, .register, map))
  }
}
