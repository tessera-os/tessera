import XCTest

@testable import TarwinSecurity

final class TarwinSecurityTests: XCTestCase {
  func testDomainContracts() {
    let rx = MappingRights(writable: false, executable: true, user: true)
    let rw = MappingRights(writable: true, executable: false, user: true)
    let kw = MappingRights(writable: true, executable: false, user: false)
    let wx = MappingRights(writable: true, executable: true, user: true)
    XCTAssertTrue(mappingAllowed(.signedImageCode, rx))
    XCTAssertFalse(mappingAllowed(.signedImageCode, rw))
    XCTAssertFalse(mappingAllowed(.anonymous, rx))
    XCTAssertFalse(mappingAllowed(.sealedCompileCode, wx))
    XCTAssertFalse(mappingAllowed(.kernelData, rw))
    XCTAssertFalse(mappingAllowed(.pageTable, kw))
    XCTAssertFalse(mappingAllowed(.deviceMemory, rx))
    XCTAssertFalse(mappingAllowed(.guestRam, rx))
    XCTAssertFalse(protectedRightsMayNarrow(1, 3))
    XCTAssertFalse(signerPermitted(.enrolledPlatform, .system, true, false, true, 1, false))
    XCTAssertFalse(signerPermitted(.developer, .application, false, true, false, 183, false))
    XCTAssertFalse(signerPermitted(.developer, .application, false, false, false, 90, false))
    XCTAssertFalse(signerPermitted(.device, .dynamicCode, true, false, false, 0, false))
    XCTAssertFalse(signerPermitted(.release, .driver, true, false, false, 0, true))
    XCTAssertTrue(signerPermitted(.device, .finalized, true, false, true, 0, false))
    XCTAssertEqual(processEntitlements(5, 3), 1)
  }
}
