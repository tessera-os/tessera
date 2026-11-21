import XCTest

@testable import TarwinDevice

final class EnumerateTests: XCTestCase {
  func testAllBusesFitAndARefusedVisitStopsConfigReads() {
    var scratch = PciWalkScratch()
    var calls = 0
    func read(_ a: UInt32) -> UInt32 {
      calls += 1
      guard a & 0x000f_f000 == 0 else { return .max }
      let bus = a >> 20
      switch a & 0xfff {
      case 0: return 0x1234_8086
      case 8: return bus < 255 ? 0x0604_0001 : 0x0108_0000
      case 12: return bus < 255 ? 0x0001_0000 : 0
      case 24: return bus | ((bus + 1) << 8) | (255 << 16)
      default: return .max
      }
    }
    XCTAssertFalse(
      visitEcam(3, 2, scratch: &scratch, read32: read) { _ in
        XCTFail()
        return true
      })
    XCTAssertEqual(calls, 0)
    XCTAssertFalse(visitEcam(0, 255, scratch: &scratch, read32: read) { _ in false })
    XCTAssertEqual(calls, 3)
    var count = 0
    XCTAssertTrue(
      visitEcam(0, 255, scratch: &scratch, read32: read) { f in
        XCTAssertEqual(f.bus, UInt32(count))
        XCTAssertEqual(f.parent, count - 1)
        count += 1
        return true
      })
    XCTAssertEqual(count, 256)
  }
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
