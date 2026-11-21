import TarwinLoader
@testable import TarwinW0Verify
import XCTest

final class SealedImportTests: XCTestCase {
  func testPageIsReconstructedFromImmutableBytesWithOnlyTheEagerSlotChanged() {
    var segment = [UInt8](repeating: 0x56, count: 4096 + 31)
    for i in 4104..<4112 { segment[i] = 0 }
    let original = segment
    let target = UInt64(0x0000_0700_0506_1070)
    var frame = [UInt8](repeating: 0xe3, count: 4096)
    func prepare(_ offset: Int, _ address: UInt64, _ size: Int = 4096) -> Bool {
      segment.withUnsafeBytes { src in frame.withUnsafeMutableBytes {
        stageSlot(immutable: src, offset: offset, target: address, frame: .init(rebasing: $0[..<size]))
      } }
    }
    XCTAssertFalse(prepare(4096, target)); XCTAssertFalse(prepare(4105, target))
    XCTAssertFalse(prepare(4104, target + 1)); XCTAssertFalse(prepare(4104, 16))
    XCTAssertFalse(prepare(4104, target, 4095)); XCTAssertFalse(prepare(4120, target))
    XCTAssertEqual(frame, [UInt8](repeating: 0xe3, count: 4096))
    XCTAssertTrue(prepare(4104, target))
    var expected = Array(segment[4096...]) + [UInt8](repeating: 0, count: 4096 - 31)
    expected.replaceSubrange(8..<16, with: withUnsafeBytes(of: target.littleEndian) { Array($0) })
    XCTAssertEqual(frame, expected); XCTAssertEqual(segment, original)
  }

  func testMachineSpecificSlotEncoding() {
    let t: UInt32 = 0x8b65_40d3, s: UInt64 = 0x0000_0700_0506_1070
    XCTAssertEqual(W1SlotFormat.select(machine: ElfMachine.aarch64, slot: s, tag: t),
      .armProcessIA(modifier: 0x40d3_0700_0506_1070))
    XCTAssertEqual(W1SlotFormat.select(machine: ElfMachine.x64, slot: s, tag: t), .x64IBT(tag: t))
    XCTAssertEqual(W1SlotFormat.select(machine: ElfMachine.rv64, slot: s, tag: t),
      .rv64LPAD(tag: t, label: 0x540d3))
    XCTAssertNil(W1SlotFormat.select(machine: 0, slot: s, tag: t))
  }
}
