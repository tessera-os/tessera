import XCTest

@testable import TarwinGPU

final class TimelineTests: XCTestCase {
  func testSignalPublishesBeforeWakeAndDropsDonation() {
    var t = GpuTimeline(waitLimit: 2)
    var boost: UInt32 = 0
    var visible: UInt64 = 0
    var woke: UInt64 = 0
    let donate: (UInt32) -> Void = { p in boost = p }
    let publish: (UInt64) -> Void = { v in visible = v }
    let wake: (UInt64) -> Void = { key in if visible >= 3 { woke = key } }
    XCTAssertTrue(
      t.waitFor(false, FenceWait(key: 5, target: 3, priority: 5), donate) == WaitResult.denied)
    XCTAssertTrue(
      t.waitFor(true, FenceWait(key: 5, target: 3, priority: 5), donate) == WaitResult.queued)
    XCTAssertTrue(
      t.waitFor(true, FenceWait(key: 7, target: 9, priority: 1), donate) == WaitResult.queued)
    XCTAssertTrue(boost == 5)
    XCTAssertTrue(!t.advance(false, 3, publish, wake, donate))
    XCTAssertTrue(t.advance(true, 3, publish, wake, donate))
    XCTAssertTrue(woke == 5 && boost == 1 && t.count == 1)
    XCTAssertTrue(!t.advance(true, 1, publish, wake, donate))
    XCTAssertTrue(t.cancel(7, donate))
    XCTAssertTrue(boost == 0 && visible == 3)
  }

  func testDoorbellRefusesNonPageRangesAndRevokedSlots() {
    let ok: (UInt64, UInt64, UInt64, UInt64) -> Bool = { p, o, b, e in
      return p == 2 && o == 16384 && b == 16384 && e == 7
    }
    let g = DoorbellGrant(process: 2, page: 16384, slotEpoch: 7)
    XCTAssertTrue(grantDoorbell(32768, 16384, [16384], g, 7, ok))
    XCTAssertTrue(!grantDoorbell(32767, 16384, [16384], g, 7, ok))
    XCTAssertTrue(!grantDoorbell(32768, 16384, [0], g, 7, ok))
    XCTAssertTrue(!grantDoorbell(32768, 16384, [16384], g, 8, ok))
  }
}
