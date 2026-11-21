import XCTest

@testable import VirtioGuest

final class BlockRangeTests: XCTestCase {
  func testDiscardChecksFeatureCapacityAndDeviceLimitsBeforeDma() {
    var q = SplitQueue()
    XCTAssertTrue(q.initialize(4))
    let limits = BlockRangeLimits(
      capacity: 101, sectors: 16, segments: 1, alignment: 4, mayUnmap: false)
    let p = BlockPacket(op: .discard, sector: 96, bytes: 16, header: 1024, data: 2048, status: 4096)
    var request: UInt32 = 0
    let header: (UInt64, UInt32, UInt64) -> Void = { a, k, s in request = k }
    let range: (UInt64, UInt64, UInt32, UInt32) -> Void = { a, s, n, f in
      XCTAssertTrue((s == 96 && n == 5 && f == 0))
    }
    let status: (UInt64, UInt8) -> Void = { a, s in }
    let desc: (Int, UInt64, UInt32, UInt16, UInt16) -> Void = { i, a, n, f, l in }
    let avail: (Int, UInt16) -> Void = { i, h in }
    let publish: (UInt16) -> Void = { i in }
    XCTAssertTrue(
      !submitRange(&q, 1, p, 6, false, limits, 8192, header, range, status, desc, avail, publish))
    XCTAssertTrue(
      !submitRange(&q, 1, p, 5, true, limits, 8192, header, range, status, desc, avail, publish))
    XCTAssertTrue(
      !submitRange(&q, 1, p, 5, false, limits, 0, header, range, status, desc, avail, publish))
    XCTAssertTrue(request == 0)
    XCTAssertTrue(
      submitRange(&q, 1, p, 5, false, limits, 8192, header, range, status, desc, avail, publish))
    XCTAssertTrue(request == 11)
  }
}
