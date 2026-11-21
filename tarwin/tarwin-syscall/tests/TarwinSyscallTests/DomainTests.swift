import XCTest

@testable import TarwinSyscall

final class TarwinSyscallTests: XCTestCase {
  func testDomainContracts() {
    XCTAssertTrue(syscallOriginAllowed(124, 4, 100, 128))
    XCTAssertFalse(syscallOriginAllowed(126, 4, 100, 128))
    XCTAssertFalse(syscallOriginAllowed(98, 2, 100, 128))
    XCTAssertEqual(syscallTailBytes(6, 6), 0)
    XCTAssertEqual(syscallTailBytes(7, 6), 16)
    XCTAssertEqual(syscallTailBytes(9, 8), 16)
    XCTAssertEqual(syscallTailBytes(9, 7), 24)
    XCTAssertTrue(syscallTailInRange(112, 16, 100, 128))
    XCTAssertFalse(syscallTailInRange(113, 8, 100, 128))
    XCTAssertFalse(syscallTailInRange(120, 16, 100, 128))
    XCTAssertEqual(syscallStatus(0, 9), 0)
    XCTAssertEqual(syscallStatus(4, 1), 0x1_0000_0004)
  }
}
