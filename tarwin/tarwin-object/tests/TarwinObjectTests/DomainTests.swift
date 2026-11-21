import XCTest

@testable import TarwinObject

final class TarwinObjectTests: XCTestCase {
  func testDomainContracts() {
    var slot = unusedHandleSlot()
    XCTAssertTrue(slot.install(77, 2, 5, 7))
    let value = slot.name(254, 1_048_575)
    XCTAssertEqual(handleIndex(value), 1_048_575)
    XCTAssertEqual(slot.check(value, 254, 1_048_575, 2, 5), .allowed)
    XCTAssertEqual(slot.check(value, 253, 1_048_575, 2, 0), .invalidHandle)
    XCTAssertEqual(slot.check(value, 254, 1_048_575, 4, 0), .wrongType)
    XCTAssertEqual(slot.check(value, 254, 1_048_575, 2, 2), .accessDenied)
    XCTAssertEqual(slot.revoke(), 77)
    XCTAssertEqual(slot.revoke(), 0)
    XCTAssertFalse(slot.install(78, 16, 1, 7))
    XCTAssertTrue(slot.install(78, 16, 4, 7))
    XCTAssertEqual(slot.check(value, 254, 1_048_575, 0, 0), .invalidHandle)
    XCTAssertEqual(slot.name(0, 1_048_576), 0)
    XCTAssertFalse(handleMayDerive(4, 4, true))
    XCTAssertTrue(handleMayDerive(4, 4, false))
    XCTAssertTrue(handleMayDerive(5, 0xffff_ffff_ffff_ffff, true))
    XCTAssertFalse(handleMayDerive(5, 7, false))
    XCTAssertFalse(handleMayDerive(5, 0xffff_ffff_ffff_ffff, false))
    slot.generation = HandleLayout.lastGeneration
    XCTAssertEqual(slot.revoke(), 78)
    XCTAssertFalse(slot.install(78, 2, 1, 1))
    var fence = unusedHandleSlot()
    XCTAssertTrue(fence.install(97, TarwinKind.fence, 130, 130))
    let timeline = fence.name(9, 2)
    XCTAssertEqual(fence.check(timeline, 9, 2, TarwinKind.presence, 0), .wrongType)
    XCTAssertEqual(fence.check(timeline, 9, 2, TarwinKind.fence, 2), .allowed)
    XCTAssertFalse(objectKindAllocated(17))
    XCTAssertFalse(objectKindAllocated(18))
    XCTAssertFalse(objectKindAllocated(33))
  }
}
