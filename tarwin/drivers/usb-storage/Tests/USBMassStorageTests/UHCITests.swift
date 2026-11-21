import USBMassStorage
import XCTest

private final class Unassigned: UHCITransport {
  var accesses = 0
  var command: UInt16 = 1, status: UInt16 = 0x20, connected: UInt16 = 1
  var failSetup = false
  func read16(_ offset: UInt16) throws -> UInt16 {
    switch offset {
    case 0: command
    case 2: status
    case 0x10: connected
    default: 0
    }
  }
  func write16(_ offset: UInt16, _ value: UInt16) throws { accesses += 1 }
  func write32(_ offset: UInt16, _ value: UInt32) throws { accesses += 1 }
  func loadDMA(_ address: UInt32, count: Int) throws -> [UInt8] {
    accesses += 1
    return []
  }
  func loadStatus(_ address: UInt32) throws -> UInt32 {
    accesses += 1
    return 0
  }
  func storeDMA(_ address: UInt32, _ bytes: [UInt8]) throws { accesses += 1 }
  func delay(milliseconds: Int) throws {
    accesses += 1
    if failSetup { throw StorageError.transport }
  }
}
final class UHCITests: XCTestCase {
  func testRefusesUnalignedOrAliasedPages() {
    XCTAssertNil(UHCIPages(frames: 0, schedule: 4096, bounce: 4096))
    XCTAssertNil(UHCIPages(frames: 4096, schedule: 4096, bounce: 8192))
    XCTAssertNil(UHCIPages(frames: 4096, schedule: 8192, bounce: 4096))
    XCTAssertNil(UHCIPages(frames: 0, schedule: 0x1110, bounce: 8192))
  }
  func testCannotConfigureAnAlreadyRunningControllerOrUseUnclaimedEndpoints() throws {
    let io = Unassigned()
    let pages = UHCIPages(frames: 0x1000_0000, schedule: 0x2000_0000, bounce: 0x3000_0000)!
    XCTAssertNil(UHCIStorageBus(io: io, pages: pages, rootPort: 2))
    let bus = UHCIStorageBus(io: io, pages: pages, rootPort: 0)!
    XCTAssertThrowsError(try bus.stop())
    XCTAssertThrowsError(try bus.configure())
    XCTAssertThrowsError(try bus.configure())
    XCTAssertThrowsError(try bus.getMaxLUN(interface: 0))
    XCTAssertThrowsError(try bus.bulkOut(1, bytes: [1]))
    XCTAssertThrowsError(try bus.clearHalt(0x81))
    XCTAssertThrowsError(try bus.stop())
    XCTAssertEqual(io.accesses, 0)
  }
  func testStopAfterAcceptedColdControllerRequiresValidHaltAcknowledgement() throws {
    let io = Unassigned()
    io.command = 0
    io.failSetup = true
    let pages = UHCIPages(frames: 4096, schedule: 8192, bounce: 12288)!
    let bus = UHCIStorageBus(io: io, pages: pages, rootPort: 0)!
    XCTAssertThrowsError(try bus.configure())
    XCTAssertGreaterThan(io.accesses, 0)
    io.failSetup = false
    for status: UInt16 in [0xffff, 0x30, 0x28, 0] {
      io.status = status
      XCTAssertThrowsError(try bus.stop())
    }
    io.status = 0x20
    XCTAssertNoThrow(try bus.stop())
    XCTAssertThrowsError(try bus.configure())
  }
}
