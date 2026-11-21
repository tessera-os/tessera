import XCTest

@testable import TarwinLoader

final class W0EntryTests: XCTestCase {
  func testArmVeneerRequiresFileBackedBody() {
    var bytes = [UInt8](repeating: 0, count: 128)
    func put(_ value: UInt32, _ at: Int) {
      for i in 0..<4 { bytes[at + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    put(1, 0)
    put(5, 4)
    put(64, 8)
    put(0x4000, 16)
    put(64, 32)
    put(w0SinglePointerTag, 76)
    put(0xd503_245f, 80)
    func accepts(_ branch: UInt32) -> Bool {
      put(branch, 84)
      return bytes.withUnsafeBytes {
        ELFReader(bytes: $0).validW0Entry(0x4010, machine: 183, programs: 0..<56)
      }
    }
    XCTAssertTrue(accepts(0x1400_0001))  // forward to the first instruction after the veneer
    XCTAssertTrue(accepts(0x17ff_fffb))  // backward to the start of the segment
    XCTAssertFalse(accepts(0xd503_201f))  // no branch
    XCTAssertFalse(accepts(0x9400_0001))  // call, not a tail branch
    XCTAssertFalse(accepts(0x1400_0000))  // self
    XCTAssertFalse(accepts(0x17ff_fffe))  // tag
    XCTAssertFalse(accepts(0x1400_000b))  // past file-backed RX bytes
    put(20, 32)
    XCTAssertFalse(accepts(0x1400_0001))  // branch instruction truncated
  }
}
