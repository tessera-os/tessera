import KCore
import TarwinDevice
import XCTest

private struct Blob: ByteSource {
  let bytes: [UInt8]
  func byteCount() -> UInt64 { UInt64(bytes.count) }
  func byteAt(_ p: UInt64) -> UInt8 { bytes[Int(p)] }
}
private func cells(_ values: UInt32...) -> [UInt8] {
  values.flatMap { v in [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: v >> $0) } }
}
private struct Tree {
  var body: [UInt8] = [], names: [UInt8] = []
  mutating func pad() { while body.count % 4 != 0 { body.append(0) } }
  mutating func begin(_ name: String) {
    body += cells(1) + name.utf8 + [0]
    pad()
  }
  mutating func end() { body += cells(2) }
  mutating func prop(_ name: String, _ value: [UInt8]) {
    body += cells(3, UInt32(value.count), UInt32(names.count)) + value
    names += Array(name.utf8) + [0]
    pad()
  }
  mutating func bus(_ name: String, a: UInt32 = 1, z: UInt32 = 1) {
    begin(name)
    prop("#address-cells", cells(a))
    prop("#size-cells", cells(z))
  }
  mutating func device(_ address: UInt32, _ length: UInt32, malformed: Bool = false) {
    begin("virtio@100")
    prop("compatible", Array("virtio,mmio".utf8) + (malformed ? [] : [0]))
    prop("reg", cells(address, length))
    prop("interrupts", cells(5))
    end()
  }
  func blob(badEnd: Bool = false) -> Blob {
    let structure = body + cells(badEnd ? 11 : 9)
    let strings = 56 + structure.count
    return Blob(
      bytes: cells(
        0xd00d_feed, UInt32(strings + names.count), 56, UInt32(strings), 40, 17, 16, 0,
        UInt32(names.count), UInt32(structure.count)) + Array(repeating: 0, count: 16) + structure
        + names)
  }
}
final class FirmwareMmioTests: XCTestCase {
  private func root() -> Tree {
    var t = Tree()
    t.bus("", a: 2)
    t.prop("interrupt-parent", cells(17))
    return t
  }
  func testNestedTranslationAndInheritedInterrupts() {
    var t = root()
    t.bus("outer")
    t.prop("compatible", Array("simple-bus".utf8) + [0])
    t.prop("ranges", cells(0, 1, 0x2000, 0x10000))
    t.bus("inner")
    t.prop("compatible", Array("vendor,custom\0simple-bus\0".utf8))
    t.prop("ranges", cells(0, 0x1000, 0x1000))
    t.device(0x100, 0x200)
    t.end()
    t.end()
    t.end()
    let blob = t.blob()
    let actual = firmwareVirtioMmio(blob)
    XCTAssertEqual(actual?.count, 1)
    let d = actual?.first
    XCTAssertEqual(d?.registers, DeviceRange(base: 0x1_0000_3100, length: 0x200))
    XCTAssertEqual(d?.interruptParent, 17)
    XCTAssertNotEqual(d?.node, d?.parent)
    XCTAssertEqual(d?.interrupts?.length, 4)
    XCTAssertEqual(blob.byteAt((d?.interrupts?.at ?? 0) + 3), 5)
    XCTAssertNil(firmwareVirtioMmio(t.blob(badEnd: true)))
  }
  func testDisabledAncestorAndMissingTranslation() {
    for disabled in [false, true] {
      var t = root()
      t.bus("soc")
      t.prop("compatible", Array("simple-bus\0".utf8))
      if disabled { t.prop("status", Array("disabled\0".utf8)) }
      t.device(0x100, 0x200)
      t.end()
      t.end()
      if disabled {
        XCTAssertEqual(firmwareVirtioMmio(t.blob())?.count, 0)
      } else {
        XCTAssertNil(firmwareVirtioMmio(t.blob()))
      }
    }
  }
  func testRejectsCrossingAliasedAndMalformedMappings() {
    for kind in 0...4 {
      var t = root()
      t.bus("soc")
      t.prop("compatible", Array("simple-bus\0".utf8))
      switch kind {
      case 0: t.prop("ranges", cells(0, 0, 0x2000, 0x200))
      case 1: t.prop("ranges", cells(0, 0, 0x2000, 0x400, 0, 0, 0x5000, 0x400))
      case 2: t.prop("ranges", cells(0, .max, .max - 15, 1024))
      default: t.prop("ranges", [])
      }
      t.device(0x100, 0x200, malformed: kind == 3)
      if kind == 4 { t.device(0x200, 0x200) }
      t.end()
      t.end()
      XCTAssertNil(firmwareVirtioMmio(t.blob()), "case \(kind)")
    }
  }
}
