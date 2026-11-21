import XCTest

@testable import NativeDriverKit

final class AccessTests: XCTestCase {
  func testNoncoherentOwnershipNeverChangesAfterFailedCacheMaintenance() {
    var b = NativeDmaBuffer(handle: 5, iova: 8192, length: 4096, direction: .fromDevice)
    let failSync: (UInt64, DmaDirection) -> Bool = { h, d in return false }
    let sync: (UInt64, DmaDirection) -> Bool = { h, d in return h == 5 && d == .fromDevice }
    let close: (UInt64) -> Bool = { h in return h == 5 }
    XCTAssertTrue(b.suitable(4096, 8192))
    XCTAssertTrue(!b.suitable(4096, 2048))
    XCTAssertTrue(!b.prepareForDevice(failSync))
    XCTAssertTrue(b.prepareForDevice(sync))
    XCTAssertTrue(!b.retire(close))
    XCTAssertTrue(!b.completeFromDevice(failSync))
    XCTAssertTrue(b.owner == BufferOwner.device)
    XCTAssertTrue(b.completeFromDevice(sync))
    XCTAssertTrue(b.retire(close))
    XCTAssertTrue(!b.prepareForDevice(sync))
  }

  func testDriverApiRefusesExpiredFutureOrPreTarwinDrivers() {
    XCTAssertTrue(compatibleDriver(27, 10, 26, 11))
    XCTAssertTrue(!compatibleDriver(27, 11, 26, 11))
    XCTAssertTrue(!compatibleDriver(26, 11, 26, 10))
    XCTAssertTrue(!compatibleDriver(26, 11, 26, 12))
  }
}
