import XCTest

@testable import UFSDriver

final class LogicalUnitsTests: XCTestCase {
  func testShortTransfersAreNotExtraUnits() throws {
    var data = [UInt8](repeating: 0, count: 64)
    data[3] = 16
    data[9] = 4
    data[17] = 9
    data[25] = 125
    var response = [UInt8](repeating: 0, count: 16)
    response[1] = 0x20
    response.field(12, 40, 4, big: true)
    XCTAssertEqual(try reportedUnits(response: response, data: data, expected: 2), [4, 9])
    for (at, byte) in [(1, 0), (1, 0x40), (1, 0x60), (7, 2), (15, 41), (15, 39), (15, 65), (15, 0)]
    {
      var r = response
      r[at] = UInt8(byte)
      XCTAssertThrowsError(try reportedUnits(response: r, data: data, expected: 2))
    }
    response[1] = 0
    response[15] = 0
    XCTAssertEqual(
      try reportedUnits(response: response, data: Array(data.prefix(24)), expected: 2), [4, 9])
  }
  func testRejectsInvalidAddressesAndInventory() throws {
    var data = [UInt8](repeating: 0, count: 24)
    data[3] = 16
    data[9] = 2
    data[17] = 127
    let response = [UInt8](repeating: 0, count: 16)
    for (at, byte) in [(3, 15), (4, 1), (8, 0x40), (9, 128), (17, 2), (23, 1)] {
      var invalid = data
      invalid[at] = UInt8(byte)
      XCTAssertThrowsError(try reportedUnits(response: response, data: invalid, expected: 2))
    }
    for expected: UInt8 in [0, 1, 3, 129] {
      XCTAssertThrowsError(try reportedUnits(response: response, data: data, expected: expected))
    }
  }
}
