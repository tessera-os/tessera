import XCTest

@testable import TarwinDevice

final class EnumerateTests: XCTestCase {
  func testEnumeratesBridgeAndMultifunctionWithNonzeroBusOrigin() {
    let read: (UInt32) -> UInt32 = { address in
      if address == 0 || address == 0x1000 || address == 0x100000 { return 0x1234_8086 }
      if address == 12 { return 0x0081_0000 }
      if address == 8 { return 0x0604_0001 }
      if address == 24 { return 0x222120 }
      return 0xffff_ffff
    }
    let functions = enumerateEcam(0x20, 0x22, read)
    XCTAssertTrue(functions.count == 3)
    XCTAssertTrue(functions[1].functionNumber == 1)
    XCTAssertTrue(functions[2].bus == 0x21 && functions[2].parent == 0)
    let absent = enumerateEcam(255, 255, { offset in return 0xffff_ffff })
    XCTAssertTrue(absent.count == 0)
  }
}
