import XCTest

@testable import TarwinPower

final class WakeTests: XCTestCase {
  func testLocksAreAttributedAndCannotBeReleasedByAnotherProcess() {
    var locks = WakeLocks(limit: 2)
    XCTAssertTrue(locks.acquire(10, .system, false) == 0)
    let device = locks.acquire(10, .device(9), true)
    XCTAssertTrue(device != 0 && locks.preventsSleep(.device(9)) && locks.preventsSleep(.system))
    XCTAssertTrue(!locks.preventsSleep(.device(8)))
    XCTAssertTrue(!locks.release(11, device))
    let system = locks.acquire(11, .system, true)
    XCTAssertTrue(system != 0 && locks.preventsSleep(.device(8)))
    XCTAssertTrue(locks.acquire(12, .system, true) == 0)
    locks.dropProcess(10)
    XCTAssertTrue(locks.release(11, system))
    XCTAssertTrue(!locks.preventsSleep(.system))
  }

  func testWakePatternRequiresSignificantBitsAndEntirePayload() {
    let p = WakePattern(offset: 1, data: [0xa5, 0xbb], mask: [0xf0, 0xff])
    XCTAssertTrue(p.matches([0, 0xaf, 0xbb]))
    XCTAssertTrue(!p.matches([0, 0xa5]))
    XCTAssertTrue(!p.matches([0, 0xa5, 0xba]))
    let emptyMask = WakePattern(offset: 0, data: [0], mask: [0])
    XCTAssertTrue(!emptyMask.matches([0]))
  }
}
