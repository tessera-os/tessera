import XCTest

@testable import TarwinLoader

final class RIDLExportTests: XCTestCase {
  func testOnlyExactDefinedTypedFunctionInRealRXSectionResolves() {
    let name = Array("_RIDL17Fixture4testF_v123456789abcdef0".utf8)
    let tag: UInt32 = 0x1234_5678
    var bytes = [UInt8](repeating: 0, count: 2048)
    func put(_ p: Int, _ x: UInt64, _ n: Int = 8) {
      for i in 0..<n { bytes[p + i] = UInt8(truncatingIfNeeded: x >> (8 * i)) }
    }
    let table = 256
    let sym = table + 64
    let str = table + 128
    let code = table + 192
    put(40, UInt64(table))
    put(60, 4, 2)
    put(64, 1, 4)
    put(68, 5, 4)
    put(72, 1024)
    put(80, 0x4000)
    put(96, 64)
    put(sym + 4, 11, 4)
    put(sym + 24, 640)
    put(sym + 32, 48)
    put(sym + 40, 2, 4)
    put(sym + 56, 24)
    put(str + 4, 3, 4)
    put(str + 24, 800)
    put(str + 32, UInt64(2 + name.count))
    bytes.replaceSubrange(801..<801 + name.count, with: name)
    put(code + 4, 1, 4)
    put(code + 8, 6)
    put(code + 16, 0x4000)
    put(code + 24, 1024)
    put(code + 32, 64)
    let s = 664
    put(s, 1, 4)
    put(s + 4, 0x12, 1)
    put(s + 6, 3, 2)
    put(s + 8, 0x4010)
    put(s + 16, 8)
    put(1036, UInt64(tag), 4)
    put(1040, 0xd503_245f, 4)
    let good = bytes
    func lookup(_ request: [UInt8], _ expected: UInt32) -> UInt64? {
      bytes.withUnsafeBytes { b in
        request.withUnsafeBytes { n in
          ELFReader(bytes: b).exportedFunction(n, tag: expected, machine: 183, programs: 64..<120)
        }
      }
    }
    XCTAssertEqual(lookup(name, tag), 0x4010)
    XCTAssertNil(lookup(Array(name.dropLast()), tag))
    XCTAssertNil(lookup(name, tag + 1))
    for (p, x, n): (Int, UInt64, Int) in [
      (s + 4, 0x22, 1), (s + 4, 0x11, 1), (s + 5, 2, 1), (s + 6, 0, 2), (s + 6, 0xfff1, 2),
      (s + 8, 0x4014, 8), (s + 16, 49, 8), (code + 8, 7, 8), (code + 24, 1028, 8), (68, 6, 4),
      (1040, 0xd503_201f, 4), (sym + 40, 99, 4), (sym + 56, 16, 8), (str + 32, .max, 8),
      (s, 9999, 4), (sym + 24, 40, 8), (64, 4, 4),
    ] {
      bytes = good
      put(p, x, n)
      XCTAssertNil(lookup(name, tag), "field \(p)")
    }
    bytes = good
    bytes.replaceSubrange(688..<712, with: good[s..<s + 24])
    put(sym + 32, 72)
    XCTAssertNil(lookup(name, tag))
  }
}
