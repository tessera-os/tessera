import TarwinLoader
import XCTest

private struct ImageFixture {
  var bytes = [UInt8](repeating: 0, count: 1024)
  mutating func put(_ value: UInt64, at: Int, width: Int) {
    for i in 0..<width { bytes[at + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
  }
  init(_ machine: UInt16, finalizer: Bool) {
    put(0x464c_457f, at: 0, width: 4)
    bytes[4...6] = [2, 1, 1]
    put(3, at: 16, width: 2)
    put(UInt64(machine), at: 18, width: 2)
    put(1, at: 20, width: 4)
    put(0x4100, at: 24, width: 8)
    put(64, at: 32, width: 8)
    put(64, at: 52, width: 2)
    put(56, at: 54, width: 2)
    put(2, at: 56, width: 2)
    put(1, at: 64, width: 4)
    put(5, at: 68, width: 4)
    put(0x4000, at: 80, width: 8)
    put(0x120, at: 96, width: 8)
    put(0x200, at: 104, width: 8)
    put(imagePage(machine), at: 112, width: 8)
    put(4, at: 120, width: 4)
    put(512, at: 128, width: 8)
    var pos = 512
    for kind in 1...7 where kind != 6 || finalizer {
      let n = kind == 1 ? 32 : 1
      put(8, at: pos, width: 4)
      put(UInt64(n), at: pos + 4, width: 4)
      put(UInt64(kind), at: pos + 8, width: 4)
      bytes[(pos + 12)..<(pos + 20)] = Array("Tessera\0".utf8)[...]
      pos += 20 + ((n + 3) & ~3)
    }
    put(UInt64(pos - 512), at: 152, width: 8)
    bytes.removeSubrange(pos...)
  }
  func inspect(_ machine: UInt16, finalized: Bool = false, requiresEntry: Bool = true)
    -> InspectedImage?
  {
    bytes.withUnsafeBytes {
      inspectELF(
        $0, target: machine, addressLimit: 0x10000, finalized: finalized,
        requiresEntry: requiresEntry)
    }
  }
}

final class ELFTests: XCTestCase {
  func testNotesAndEntryOnSupportedMachines() throws {
    for machine in [ElfMachine.aarch64, ElfMachine.x64, ElfMachine.rv64] {
      var image = ImageFixture(machine, finalizer: false)
      let parsed = try XCTUnwrap(image.inspect(machine))
      XCTAssertEqual(parsed.notes.buildID, 532..<564)
      XCTAssertEqual(parsed.notes.signature, 584..<585)
      XCTAssertEqual(parsed.entry, 0x4100)
      XCTAssertNil(image.inspect(machine, finalized: true))
      XCTAssertNotNil(ImageFixture(machine, finalizer: true).inspect(machine, finalized: true))
      image.put(0, at: 24, width: 8)
      XCTAssertNotNil(image.inspect(machine, requiresEntry: false))
      XCTAssertNil(image.inspect(machine))
    }
  }
  func testRejectsInvalidExtentsAndNotes() {
    let good = ImageFixture(ElfMachine.rv64, finalizer: true)
    for (at, value, width): (Int, UInt64, Int) in [
      (68, 7, 4), (24, 0x4120, 8), (120, 3, 4), (120, 2, 4),
      (572, 1, 4), (524, 0, 4), (516, 0xffff_ffff, 4), (128, .max - 3, 8),
      (32, .max - 7, 8), (520, 0, 4), (96, .max, 8),
    ] {
      var image = good
      image.put(value, at: at, width: width)
      XCTAssertNil(image.inspect(ElfMachine.rv64), "offset \(at)")
    }
    for n in 0..<good.bytes.count {
      var image = good
      image.bytes.removeSubrange(n...)
      XCTAssertNil(image.inspect(ElfMachine.rv64), "prefix \(n)")
    }
  }
}
