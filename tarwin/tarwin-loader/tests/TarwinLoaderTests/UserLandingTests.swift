import XCTest
@testable import TarwinLoader

final class UserLandingTests: XCTestCase {
  func testFirstProcessAndFrameworkHaveDistinctFullTagsAndISALandings() {
    let entry: UInt64 = 0x4010
    for machine in [ElfMachine.aarch64, ElfMachine.x64, ElfMachine.rv64] {
      for tag: UInt32 in [0x4d3e_7643, 0x8b65_40d3] {
        var bytes = [UInt8](repeating: 0, count: 128)
        func put(_ value: UInt32, _ at: Int) {
          for i in 0..<4 { bytes[at + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }
        put(1, 0); put(5, 4); put(64, 8); put(0x4000, 16); put(64, 32)
        bytes[75] = 0xb8
        put(tag, 76)
        put(machine == ElfMachine.x64 ? 0xfa1e_0ff3 :
          (machine == ElfMachine.rv64 ? tag << 12 | 0x17 : 0xd503_245f), 80)
        func valid(_ pc: UInt64 = 0x4010) -> Bool {
          var hint: Int?
          return bytes.withUnsafeBytes {
            ELFReader(bytes: $0).validLocalEntry(pc, tag: tag, machine: machine,
              programs: 0..<56, hint: &hint)
          }
        }
        XCTAssertTrue(valid())
        XCTAssertFalse(valid(entry + 4))
        bytes[79] ^= 0x80  // RV64: LPAD label still matches, full tag does not.
        XCTAssertFalse(valid())
        bytes[79] ^= 0x80
        bytes[83] ^= 1
        XCTAssertFalse(valid())
        bytes[83] ^= 1
        if machine == ElfMachine.x64 {
          bytes[75] = 0x90
          XCTAssertFalse(valid())
          bytes[75] = 0xb8
        }
        put(19, 32)
        XCTAssertFalse(valid())
      }
    }
  }
}
