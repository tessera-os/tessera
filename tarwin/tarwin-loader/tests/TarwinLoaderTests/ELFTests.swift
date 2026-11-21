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
  mutating func addSections() {
    bytes += [UInt8](repeating: 0, count: 1536 - bytes.count)
    put(1024, at: 40, width: 8)
    put(64, at: 58, width: 2)
    put(4, at: 60, width: 2)
    put(1, at: 62, width: 2)
    let names = Array("\0.shstrtab\0.tirload\0.other\0".utf8)
    bytes[1344..<(1344 + names.count)] = names[...]
    put(1, at: 1088, width: 4)
    put(3, at: 1092, width: 4)
    put(1344, at: 1112, width: 8)
    put(UInt64(names.count), at: 1120, width: 8)
    put(11, at: 1152, width: 4)
    put(1, at: 1156, width: 4)
    put(1440, at: 1176, width: 8)
    put(24, at: 1184, width: 8)
    put(20, at: 1216, width: 4)
  }
  func inspect(
    _ machine: UInt16, finalized: Bool = false, requiresEntry: Bool = true,
    records: Bool = false
  )
    -> InspectedImage?
  {
    bytes.withUnsafeBytes {
      inspectELF(
        $0, target: machine, addressLimit: 0x10000, finalized: finalized,
        requiresEntry: requiresEntry, requiresLoaderRecords: records)
    }
  }
}

final class ELFTests: XCTestCase {
  func testUnsignedLinkInterchangeIsNotASignedImage() throws {
    var file = ImageFixture(ElfMachine.x64, finalizer: false)
    file.addSections()
    let start = 4096
    file.bytes += [UInt8](repeating: 0, count: 8192 - file.bytes.count)
    let section = 1800
    file.put(UInt64(section), at: 1176, width: 8)
    file.put(148, at: 1184, width: 8)
    file.put(0x3144_4c54, at: section, width: 4)
    file.put(1, at: section + 4, width: 2)
    file.put(8, at: section + 6, width: 2)
    file.put(148, at: section + 8, width: 4)
    for i in 0..<8 { file.put(i == 7 ? 148 : 144, at: section + 16 + i * 16, width: 4) }
    file.put(4, at: section + 20 + 6 * 16, width: 4)
    file.put(1, at: section + 24 + 6 * 16, width: 4)
    file.put(UInt64(start), at: 128, width: 8)
    var notes = [Int: Range<Int>]()
    var pos = start
    for (k, data): (Int, [UInt8]) in [
      (1, [UInt8](repeating: 0, count: 32)), (3, Array("[\"tessera.network.client\"]".utf8)),
      (4, [26, 11, 1, 26, 11, 1, 27, 4, 1]), (5, [6, 0] + Array("x64.v3".utf8) + [0, 0, 1, 2]),
      (7, [0, 0]),
    ] {
      file.put(8, at: pos, width: 4)
      file.put(UInt64(data.count), at: pos + 4, width: 4)
      file.put(UInt64(k), at: pos + 8, width: 4)
      file.bytes[(pos + 12)..<(pos + 20)] = Array("Tessera\0".utf8)[...]
      let d = (pos + 20)..<(pos + 20 + data.count)
      notes[k] = d
      file.bytes[d] = data[...]
      pos = (d.upperBound + 3) & ~3
    }
    file.put(UInt64(pos - start), at: 152, width: 8)
    var stack = [BlakeCv](
      repeating: BlakeCv(w0: 0, w1: 0, w2: 0, w3: 0, w4: 0, w5: 0, w6: 0, w7: 0), count: 54)
    func setID(_ image: inout ImageFixture) throws {
      let extent = try XCTUnwrap(notes[1])
      let cv = try XCTUnwrap(
        image.bytes.withUnsafeBytes { bytes in
          stack.withUnsafeMutableBufferPointer {
            unsignedBuildID(bytes, descriptor: extent, scratch: $0)
          }
        })
      for (i, w) in [cv.w0, cv.w1, cv.w2, cv.w3, cv.w4, cv.w5, cv.w6, cv.w7].enumerated() {
        image.put(UInt64(w), at: extent.lowerBound + 4 * i, width: 4)
      }
    }
    func inspect(_ image: ImageFixture) -> UnsignedArtifact? {
      image.bytes.withUnsafeBytes { bytes in
        stack.withUnsafeMutableBufferPointer {
          inspectUnsignedArtifact(
            bytes, machine: ElfMachine.x64, addressLimit: 0x10000, finalized: false,
            requiresEntry: true, scratch: $0)
        }
      }
    }
    try setID(&file)
    XCTAssertEqual(inspect(file)?.section, section..<(section + 148))
    XCTAssertNil(file.inspect(ElfMachine.x64))
    var orphan = file
    orphan.put(2, at: section + 144, width: 4)
    try setID(&orphan)
    XCTAssertNil(inspect(orphan))
    var gpu = file
    let gpuName = Array(".tirgpu\0".utf8)
    gpu.bytes[1364..<(1364 + gpuName.count)] = gpuName[...]
    gpu.put(UInt64(20 + gpuName.count), at: 1120, width: 8)
    gpu.put(1, at: 1220, width: 4)
    gpu.put(3000, at: 1240, width: 8)
    gpu.put(16, at: 1248, width: 8)
    gpu.bytes[3000..<3008] = [84, 71, 80, 85, 26, 11, 1, 0]
    try setID(&gpu)
    XCTAssertNotNil(inspect(gpu))
    gpu.put(1, at: 3008, width: 4)
    try setID(&gpu)
    XCTAssertNil(inspect(gpu))
    var corrupt = file
    corrupt.bytes[256] ^= 1
    XCTAssertNil(inspect(corrupt))
    for (kind, relative, byte): (Int, Int, UInt8) in [
      (3, 0, 123), (4, 4, 13), (5, 9, 1), (5, 11, 4), (7, 0, 2),
    ] {
      var bad = file
      let base = try XCTUnwrap(notes[kind]).lowerBound
      bad.bytes[base + relative] = byte
      try setID(&bad)
      XCTAssertNil(inspect(bad))
    }
  }
  func testLoaderSectionDiscovery() {
    var good = ImageFixture(ElfMachine.x64, finalizer: false)
    XCTAssertNil(good.inspect(ElfMachine.x64, records: true))
    good.addSections()
    XCTAssertEqual(good.inspect(ElfMachine.x64, records: true)?.loaderRecords, 1440..<1464)
    for (at, value, width): (Int, UInt64, Int) in [
      (40, .max, 8), (58, 0, 2), (60, 0xffff, 2), (62, 4, 2),
      (1092, 1, 4), (1112, .max, 8), (1120, .max, 8),
      (1152, 0xffff_ffff, 4), (1156, 8, 4), (1160, 1, 8),
      (1176, 160, 8), (1176, 256, 8), (1176, 512, 8), (1176, 1024, 8),
      (1176, 1344, 8), (1176, .max, 8), (1184, .max, 8), (1216, 11, 4),
    ] {
      var bad = good
      bad.put(value, at: at, width: width)
      XCTAssertNil(bad.inspect(ElfMachine.x64, records: true), "offset \(at)")
    }
    good.bytes[1344 + 19] = 120  // .tirloadx is not .tirload
    XCTAssertNil(good.inspect(ElfMachine.x64, records: true))
    XCTAssertNotNil(good.inspect(ElfMachine.x64))
  }
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

  func testLoadPagesCannotAliasEachOtherInFile() {
    var f = ImageFixture(ElfMachine.rv64, finalizer: false)
    f.put(3, at: 56, width: 2)
    f.put(1, at: 176, width: 4)
    f.put(6, at: 180, width: 4)
    f.put(0, at: 184, width: 8)
    f.put(0x6000, at: 192, width: 8)
    f.put(32, at: 208, width: 8)
    f.put(32, at: 216, width: 8)
    f.put(4096, at: 224, width: 8)
    XCTAssertNil(f.inspect(ElfMachine.rv64))
    f.put(0x180, at: 184, width: 8)
    f.put(0x6180, at: 192, width: 8)
    XCTAssertNil(f.inspect(ElfMachine.rv64))
    f.bytes += [UInt8](repeating: 0, count: 8192 - f.bytes.count)
    f.put(4096, at: 184, width: 8)
    f.put(0x6000, at: 192, width: 8)
    XCTAssertNotNil(f.inspect(ElfMachine.rv64))
  }
}
