import XCTest

@testable import TarwinSync

final class TarwinSyncTests: XCTestCase {
  func testDomainContracts() {
    let source = WaitAddress(frame: 18, offset: 4)
    let dest = WaitAddress(frame: 25, offset: 8)
    let wrong = WaitAddress(frame: 19, offset: 4)
    var wait = AddressWait(key: WaitAddress(frame: 0, offset: 0), queued: false, owner: 0)
    XCTAssertFalse(source.valid(4096, 8))
    XCTAssertFalse(wait.arm(source, 4096, 4, 5, 6, 9))
    XCTAssertTrue(wait.arm(source, 4096, 4, 5, 5, 9))
    XCTAssertFalse(wait.arm(source, 4096, 4, 5, 5, 9))
    XCTAssertFalse(wait.remove(wrong))
    XCTAssertFalse(wait.requeue(wrong, dest, 4096, 4, 8))
    XCTAssertTrue(wait.requeue(source, dest, 4096, 4, 8))
    XCTAssertEqual(wait.owner, 8)
    XCTAssertFalse(wait.remove(source))
    XCTAssertTrue(wait.remove(dest))
    XCTAssertEqual(wait.owner, 0)
    XCTAssertFalse(wait.remove(dest))
  }
}
