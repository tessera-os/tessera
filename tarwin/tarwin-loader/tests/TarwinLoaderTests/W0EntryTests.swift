import XCTest

@testable import TarwinLoader

final class W0EntryTests: XCTestCase {
  func testRVKernelHasItsOwnTagLabelAndDirectTail() {
    var b = [UInt8](repeating: 0, count: 128)
    func put(_ word: UInt32, _ at: Int) {
      for i in 0..<4 { b[at + i] = UInt8(truncatingIfNeeded: word >> (8 * i)) }
    }
    put(1, 0); put(5, 4); put(64, 8); put(0x4000, 16); put(64, 32)
    func accepts(_ tag: UInt32, _ label: UInt32, _ branch: UInt32) -> Bool {
      put(tag, 76); put(label << 12 | 0x17, 80); put(branch, 84)
      return b.withUnsafeBytes {
        ELFReader(bytes: $0).validW0Entry(0x4010, machine: ElfMachine.rv64, programs: 0..<56)
      }
    }
    XCTAssertTrue(accepts(0xd8d1_d4c7, 0x1d4c7, 0x0040_006f))
    XCTAssertFalse(accepts(w0SinglePointerTag, w0SinglePointerTag, 0x0040_006f))
    XCTAssertFalse(accepts(0x4d3e_7643, 0xe7643, 0x0040_006f))
    XCTAssertFalse(accepts(0xd8d1_d4c7, 0xe7643, 0x0040_006f))
    XCTAssertFalse(accepts(0xd8d1_d4c7, 0x1d4c7, 0x0040_00ef)) // JAL ra
    XCTAssertFalse(accepts(0xd8d1_d4c7, 0x1d4c7, 0x0000_006f)) // self
    XCTAssertFalse(accepts(0xd8d1_d4c7, 0x1d4c7, 0x7fe0_006f)) // outside RX
  }

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
