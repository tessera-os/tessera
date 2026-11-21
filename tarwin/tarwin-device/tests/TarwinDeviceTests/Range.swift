import XCTest

@testable import TarwinDevice

final class RangeTests: XCTestCase {
  func testRangeEndsAtLastAddress() {
    let top = DeviceRange(base: 0xffff_ffff_ffff_f000, length: 4096)
    XCTAssertTrue(top.contains(DeviceRange(base: 0xffff_ffff_ffff_ffff, length: 1)))
    XCTAssertTrue(!top.contains(DeviceRange(base: 0xffff_ffff_ffff_ffff, length: 2)))
    XCTAssertTrue(!top.overlaps(DeviceRange(base: 0, length: 1)))
    XCTAssertTrue(!deviceAligned(4096, 0))
    XCTAssertTrue(!deviceAligned(0, 3))
    XCTAssertTrue(deviceAligned(4096, 4096))
  }
}
