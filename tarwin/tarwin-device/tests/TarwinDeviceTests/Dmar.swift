import KCore
import TarwinDevice
import XCTest

private struct Bytes: ByteSource {
  var bytes: [UInt8]
  func byteCount() -> UInt64 { UInt64(bytes.count) }
  func byteAt(_ p: UInt64) -> UInt8 { bytes[Int(p)] }
  mutating func seal() {
    bytes[9] = 0
    bytes[9] = 0 &- bytes.reduce(0, &+)
  }
}
final class DmarTests: XCTestCase {
  private let direct: [UInt8] = [1, 8, 0, 0, 0, 0, 4, 1]
  private func table(_ scopes: [UInt8], all: Bool = false) -> Bytes {
    var b = Bytes(bytes: [UInt8](repeating: 0, count: 64) + scopes)
    b.bytes.replaceSubrange(0..<4, with: "DMAR".utf8)
    b.bytes[4] = UInt8(b.bytes.count)
    b.bytes[8] = 1
    b.bytes[36] = 38
    b.bytes[50] = UInt8(b.bytes.count - 48)
    b.bytes[52] = all ? 1 : 0
    b.bytes[54] = 7
    b.bytes[58] = 0xd9
    b.bytes[59] = 0xfe
    b.seal()
    return b
  }
  func testPrefersNoUnitToIncompleteOrAmbiguousTranslationRules() {
    let good = table(direct)
    let r = firmwareVtd(good, segment: 7, requester: 33) {
      $0 == DeviceRange(base: 0xfed9_0000, length: 4096)
    }
    XCTAssertEqual(r?.addressBits, 39)
    XCTAssertNil(firmwareVtd(good, segment: 7, requester: 32) { _ in true })
    XCTAssertNil(firmwareVtd(good, segment: 6, requester: 33) { _ in true })
    XCTAssertNil(firmwareVtd(good, segment: 7, requester: 33) { _ in false })
    var bad: [Bytes] = [table(direct + direct), table(direct, all: true), table(direct + [1])]
    for (at, v): (Int, UInt8) in [
      (48, 1), (36, 63), (38, 1), (50, 16), (52, 2), (53, 1), (56, 1), (62, 1), (64, 2), (65, 10),
      (70, 32), (71, 8),
    ] {
      var t = good
      t.bytes[at] = v
      t.seal()
      bad.append(t)
    }
    var torn = good
    torn.bytes[12] ^= 1
    bad.append(torn)
    for t in bad {
      var granted = false
      XCTAssertNil(
        firmwareVtd(t, segment: 7, requester: 33) { _ in
          granted = true
          return true
        })
      XCTAssertFalse(granted)
    }
  }
  func testNeverReturnsAnInterruptScopeAsADmaRequester() {
    let t = table([3, 8, 0, 0, 1, 0, 4, 1], all: true)
    XCTAssertNil(firmwareVtd(t, segment: 7, requester: 33) { _ in true })
    XCTAssertNotNil(firmwareVtd(t, segment: 7, requester: 32) { _ in true })
  }
}
