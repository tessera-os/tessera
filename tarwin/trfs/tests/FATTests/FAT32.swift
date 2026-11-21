import TarwinFAT
import XCTest

// A sparse medium with a two-cluster root and file data beyond the 16-bit boundary.
private struct Fat32Image: FatMedia {
  let copies = 2, fatSectors = 520, reserved = 32, clusters = 66000
  var first: Int { reserved + copies * fatSectors }
  var byteCount: UInt64 { UInt64(first + clusters) * 512 }
  var pages: [Int: [UInt8]] = [:]
  mutating func put(_ sector: Int, _ at: Int, _ value: Int, _ width: Int) {
    var page = pages[sector] ?? Array(repeating: 0, count: 512)
    for n in 0..<width { page[at + n] = UInt8(truncatingIfNeeded: value >> (n * 8)) }
    pages[sector] = page
  }
  mutating func entry(_ table: Int, _ cluster: Int, _ value: Int) {
    put(reserved + table * fatSectors + cluster / 128, (cluster % 128) * 4, value, 4)
  }
  init() {
    put(0, 510, 0xaa55, 2)
    put(0, 11, 512, 2)
    put(0, 13, 1, 1)
    put(0, 14, reserved, 2)
    put(0, 16, copies, 1)
    put(0, 21, 0xf8, 1)
    put(0, 32, first + clusters, 4)
    put(0, 36, fatSectors, 4)
    put(0, 44, 5, 4)
    for copy in 0..<copies {
      // FAT32 ignores the high four bits even when the copies differ there.
      let spare = (copy + 3) << 28
      for (id, v) in [
        (0, 0x0fff_fff8), (1, 0x0fff_ffff), (5, 0x10001), (0x10001, 0x0fff_fff8),
        (0x10000, 3), (3, 0x0fff_ffff),
      ] {
        entry(copy, id, v | spare)
      }
    }
    let firstRoot = first + 3
    for i in stride(from: 0, to: 512, by: 32) { put(firstRoot, i, 0xe5, 1) }
    let secondRoot = first + 0x10001 - 2
    for (i, v) in "BINARY  DAT".utf8.enumerated() { put(secondRoot, i, Int(v), 1) }
    put(secondRoot, 11, 32, 1)
    put(secondRoot, 20, 1, 2)
    put(secondRoot, 28, 515, 4)
    put(first + 0x10000 - 2, 511, 0x81, 1)
    put(first + 1, 0, 0x127f00, 3)
  }
  func read(at: UInt64, count: Int) -> [UInt8]? {
    guard at <= byteCount, count >= 0, UInt64(count) <= byteCount - at else { return nil }
    var data = [UInt8](repeating: 0, count: count)
    for (sector, page) in pages {
      let start = sector * 512 - Int(at)
      let lo = max(0, start)
      let hi = min(count, start + 512)
      if lo < hi { data.replaceSubrange(lo..<hi, with: page[(lo - start)..<(hi - start)]) }
    }
    return data
  }
}
final class Fat32Tests: XCTestCase {
  func testChainedRootHighClusterAndSelectedFAT() throws {
    var image = Fat32Image()
    for mirrored in [true, false] {
      if !mirrored {
        image.put(0, 40, 0x81, 2)
        image.entry(0, 5, 0)
        image.entry(0, 0x10000, 0x0fff_fff7)
      }
      let v = try FatVolume(image)
      let id = try v.lookup(parent: v.root, name: Array("binary.dat".utf8))
      XCTAssertEqual(try v.bytes(node: id, offset: 511, count: 512), [0x81, 0, 0x7f, 0x12])
      XCTAssertEqual(try v.entry(parent: v.root, index: 0)?.id, id)
    }
  }
  func testRejectsBadRootLinksGeometryAndMirror() {
    let base = Fat32Image()
    for (at, value, width) in [
      (17, 1, 2), (40, 0x82, 2), (40, 0x100, 2), (42, 1, 2), (44, 0, 4),
      (44, 70000, 4), (36, 1, 4), (32, 64000, 4),
    ] {
      var image = base
      image.put(0, at, value, width)
      XCTAssertThrowsError(try FatVolume(image))
    }
    var image = base
    image.entry(1, 5, 2)
    XCTAssertThrowsError(try FatVolume(image))
    for (id, next) in [(5, 5), (5, 0x0fff_fff7), (0x10000, 5), (0x10000, 0), (3, 70000)] {
      var image = base
      for table in 0..<2 { image.entry(table, id, next) }
      XCTAssertThrowsError(try FatVolume(image))
    }
  }
}
