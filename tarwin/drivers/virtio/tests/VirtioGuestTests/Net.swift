import XCTest

@testable import VirtioGuest

final class NetTests: XCTestCase {
  func testVirtioNetNoOffloadBuffersAreBoundedAndDirectionSpecific() {
    var q = SplitQueue()
    XCTAssertTrue(q.initialize(4))
    var flags: UInt16 = 0
    var cleared: UInt32 = 0
    let p = NetPacket(header: 0x1000, frame: 0x2000, bytes: 1518)
    let clear: (UInt64, UInt32) -> Void = { h, n in cleared = n }
    let desc: (Int, UInt64, UInt32, UInt16, UInt16) -> Void = { i, a, n, f, l in
      flags = (flags << 4) | f
    }
    XCTAssertTrue(submitFrame(&q, 2, p, true, 1518, clear, desc, { i, h in }, { idx in }))
    XCTAssertTrue(cleared == 12 && flags == 0x32)
    XCTAssertTrue(frameResult(true, 1518, 26, 0, 0) == FrameResult.received(14))
    XCTAssertTrue(frameResult(true, 1518, 1531, 0, 0) == FrameResult.invalid)
    XCTAssertTrue(frameResult(true, 1518, 26, 1, 0) == FrameResult.invalid)
    XCTAssertTrue(frameResult(false, 1518, 0, 0, 0) == FrameResult.sent)
    flags = 0
    XCTAssertTrue(submitFrame(&q, 3, p, false, 1518, clear, desc, { i, h in }, { idx in }))
    XCTAssertTrue(flags == 0x10)
  }
}
