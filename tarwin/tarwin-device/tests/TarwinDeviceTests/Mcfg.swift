import KCore
import TarwinDevice
import XCTest

private struct Table: ByteSource {
  var b: [UInt8]
  func byteCount() -> UInt64 { UInt64(b.count) }
  func byteAt(_ i: UInt64) -> UInt8 { b[Int(i)] }
  mutating func put(_ v: UInt64, _ at: Int, _ size: Int) {
    for i in 0..<size { b[at + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) }
  }
  mutating func seal() {
    b[9] = 0
    b[9] = 0 &- b.reduce(0, &+)
  }
}
private func table(_ entries: [(UInt64, UInt16, UInt8, UInt8)]) -> Table {
  var t = Table(b: Array(repeating: 0, count: 44 + 16 * entries.count))
  t.put(0x4746_434d, 0, 4)
  t.put(UInt64(t.b.count), 4, 4)
  t.b[8] = 1
  for (i, e) in entries.enumerated() {
    let p = 44 + i * 16
    t.put(e.0, p, 8)
    t.put(UInt64(e.1), p + 8, 2)
    t.b[p + 10] = e.2
    t.b[p + 11] = e.3
  }
  t.seal()
  return t
}
final class McfgTests: XCTestCase {
  func testSegmentAndNonzeroStartBusInAbsolutePhysicalWindow() {
    let t = table([(0xa000_0000, 7, 32, 63), (0xc000_0000, 9, 0, 255), (0xa000_0000, 7, 64, 127)])
    let w = firmwareEcam(t, segment: 7, bus: 35) {
      $0 == DeviceRange(base: 0xa200_0000, length: 32 << 20)
    }
    XCTAssertEqual(w?.address(bus: 32, device: 0, function: 0, register: 0, width: 4), 0xa200_0000)
    XCTAssertEqual(
      w?.address(bus: 63, device: 31, function: 7, register: 4094, width: 2), 0xa3ff_fffe)
    for (b, d, f, r, z): (UInt32, UInt32, UInt32, UInt32, UInt32) in [
      (31, 0, 0, 0, 1), (64, 0, 0, 0, 1), (32, 32, 0, 0, 1), (32, 0, 8, 0, 1), (32, 0, 0, 4096, 1),
      (32, 0, 0, 4095, 2), (32, 0, 0, 0, 8), (32, 0, 0, 0, 0),
    ] {
      XCTAssertNil(w?.address(bus: b, device: d, function: f, register: r, width: z))
    }
    XCTAssertNil(firmwareEcam(t, segment: 8, bus: 35) { _ in true })
    XCTAssertNil(firmwareEcam(t, segment: 7, bus: 35) { _ in false })
  }
  func testInvalidOrAliasedTableCannotAuthorizeMmio() {
    let good = table([(0xe000_0000, 0, 0, 127)])
    var invalid = [
      table([]), table([(0xe000_0000, 0, 0, 127), (0xe000_0000, 1, 1, 1)]),
      table([(0xe000_0000, 0, 0, 127), (0xf000_0000, 0, 32, 63)]),
      table([(0xe000_0000, 0, 0, 127), (0, 1, 1, 1)]),
      table([(0xe000_0000, 0, 0, 127), (0xffff_ffff_ff00_0000, 1, 128, 255)]),
      table([(0xe000_0000, 0, 0, 127), (0xffff_ffff_ffe0_0000, 1, 0, 15)]),
    ]
    for (i, v): (Int, UInt8) in [(0, 0), (4, 59), (8, 2), (40, 1), (44, 1), (54, 128), (56, 1)] {
      var t = good
      t.b[i] = v
      t.seal()
      invalid.append(t)
    }
    var corrupt = good
    corrupt.b[9] ^= 1
    invalid.append(corrupt)
    for t in invalid {
      XCTAssertNil(
        firmwareEcam(t, segment: 0, bus: 2) { _ in
          XCTFail("queried invalid aperture")
          return true
        })
    }
  }
}
