import TarwinDevice
import XCTest

private struct Bus: ColdVirtRegisters {
  var words: [UInt64: UInt32] = [
    0x0800_ffe8: 0x3b, 0x080a_0008: 0x0100_0011, 0x080a_0000: 2, 0x0905_0044: 0x1000,
    0x0905_0fe0: 0x84, 0x0905_0fe4: 0xb4, 0x0905_0ff0: 0x0d,
    0x0905_0ff4: 0xf0, 0x0905_0ff8: 5, 0x0905_0ffc: 0xb1,
    0x40_1000_0000: 0x0008_1b36, 0x40_1000_8000: 0x1042_1af4, 0x40_1001_0000: 0x1044_1af4,
  ]
  var fwVersion: UInt32 = 1, writes: [UInt64] = []
  var fault: UInt64?, reply: UInt32 = 0x10_1000, busyAfterWrite = false
  func read32(_ p: UInt64) -> UInt32? {
    if p == fault { return nil }
    if busyAfterWrite && !writes.isEmpty && p == 0x0905_0024 { return 1 }
    if let v = words[p] { return v }
    if (0x0a00_0000..<0x0a00_4000).contains(p), p & 511 == 0 { return 0x7472_6976 }
    if (0x40_1000_0000..<0x40_1010_0000).contains(p), p & 4095 == 0 { return .max }
    return 0
  }
  mutating func write32(_ p: UInt64, _ value: UInt32) -> Bool {
    XCTAssertEqual(value, 0x8010_1000)
    writes.append(p)
    words[p] = reply
    return true
  }
  func fwConfigWord(_ selector: UInt16) -> UInt32? { selector == 0 ? 0x554d_4551 : fwVersion }
}

final class ColdVirtPCITests: XCTestCase {
  private struct Firmware: VirtBootFenceBus {
    var model = Bus()
    var wide: [UInt64: UInt64] = [:], stores: [UInt64] = []
    var stuck: UInt64?, synced = true, published = false
    init() {
      model.words[0x0905_0000] = 0x10
      model.words[0x0905_0004] = 16 | (3 << 21)
      for (i, fn): (Int, UInt64) in [UInt64(0x40_1000_8000), 0x40_1001_0000].enumerated() {
        let bar = UInt32(0x2000_0000 + 65536 * i)
        model.words[fn + 4] = 0x10_0006
        model.words[fn + 0x14] = i == 0 ? 0x1000_1000 : 0x1000_0000
        model.words[fn + 0x20] = bar | 12
        model.words[fn + 0x34] = 0x70
        model.words[fn + 0x70] = 0x0110_0009
        model.words[fn + 0x74] = 4
        model.words[fn + 0x7c] = 56
        model.words[UInt64(bar) + 4] = 3
        model.words[UInt64(bar) + 20] = 15
      }
    }
    func fwConfigWord(_ selector: UInt16) -> UInt32? { model.fwConfigWord(selector) }
    func read32(_ p: UInt64) -> UInt32? { model.read32(p) }
    func read8(_ p: UInt64) -> UInt8? { read32(p).map { UInt8(truncatingIfNeeded: $0) } }
    func read64(_ p: UInt64) -> UInt64? { wide[p] }
    mutating func write8(_ p: UInt64, _ v: UInt8) -> Bool { write32(p, UInt32(v)) }
    mutating func write16(_ p: UInt64, _ v: UInt16) -> Bool {
      let old = model.words[p, default: 0]
      return write32(p, old & 0xffff_0000 | UInt32(v))
    }
    mutating func write32(_ p: UInt64, _ v: UInt32) -> Bool {
      stores.append(p)
      if stuck == p { return true }
      if p == 0x0905_0044 { return model.write32(p, v) }
      if p == 0x0905_0020 { model.words[p + 4] = v }
      if p == 0x0905_0098 && synced { model.words[p + 4] = v }
      model.words[p] = v
      return true
    }
    mutating func write64(_ p: UInt64, _ v: UInt64) -> Bool {
      if p < 0x4000_0000 { XCTAssertTrue(published) }
      stores.append(p)
      if p != stuck { wide[p] = v }
      return true
    }
    mutating func publishStores() { published = true }
    mutating func fence(
      _ span: DeviceRange = DeviceRange(base: 0x4100_0000, length: 16384),
      layout: VirtBootPCILayout = .lowOnly
    )
      -> VirtBootFenceResult
    {
      [span].withUnsafeBufferPointer {
        denyVirtBootDMA(
          table: 0x4200_0000, commands: 0x4200_1000, protected: $0, layout: layout, bus: &self)
      }
    }
  }
  func testDrainBeforePublishingDenyTableAndSync() {
    var b = Firmware()
    XCTAssertEqual(b.fence(), .streamsDenied)
    XCTAssertEqual(b.read32(0x0905_0024), 9)
    XCTAssertEqual(b.read32(0x0905_009c), 3)
    XCTAssertLessThan(
      b.stores.firstIndex(of: 0x40_1001_0004)!, b.stores.firstIndex(of: 0x4200_0000)!)
    XCTAssertEqual(b.wide[0x4200_0000 + 16 * 64], 1)
  }
  func testRejectsAliasedRAMOrBARWithoutWrites() {
    for r in [
      DeviceRange(base: 0x41ff_ffff, length: 2), DeviceRange(base: 0x4200_1fff, length: 8),
      DeviceRange(base: .max, length: 2), DeviceRange(base: 0, length: 0),
    ] {
      var b = Firmware()
      XCTAssertEqual(b.fence(r), .badMemory)
      XCTAssertTrue(b.stores.isEmpty)
    }
    var b = Firmware()
    b.model.words[0x40_1001_0020] = 0x2000_000c
    XCTAssertEqual(b.fence(), .unsupported)
    XCTAssertTrue(b.stores.isEmpty)
  }
  func testHighBARsRequirePinnedWindowAndRetainAllAddressBits() {
    var b = Firmware()
    for (fn, base): (UInt64, UInt64) in [
      (0x40_1000_8000, 0x80_0000_0000), (0x40_1001_0000, 0x80_0000_4000),
    ] {
      b.model.words[fn + 0x20] = UInt32(truncatingIfNeeded: base) | 12
      b.model.words[fn + 0x24] = UInt32(base >> 32)
      b.model.words[base + 4] = 3
      b.model.words[base + 20] = 15
    }
    XCTAssertEqual(b.fence(), .unsupported)
    XCTAssertTrue(b.stores.isEmpty)
    XCTAssertEqual(b.fence(layout: .virt11High512GiB), .streamsDenied)
    XCTAssertTrue(b.stores.contains(0x80_0000_0014))
    XCTAssertTrue(b.stores.contains(0x80_0000_4014))
  }
  func testInvalidDecodersRefuseBeforeAnyWrite() {
    let disk: UInt64 = 0x40_1000_8000
    for (offset, value): (UInt64, UInt32) in [
      (0x24, 0x100), (0x24, 0x40), (0x24, .max), (0x20, 0x4000_000c),
      (0x20, 0x3eff_000c), (0x20, 0x2000_100c), (0x20, 0x2000_0004),
      (0x14, 0x4000_0000), (0x14, 0x2001_0000), (0x14, 0x1000_0000),
    ] {
      var b = Firmware()
      b.model.words[disk + offset] = value
      XCTAssertEqual(b.fence(layout: .virt11High512GiB), .unsupported)
      XCTAssertTrue(b.stores.isEmpty)
    }
  }
  func testNoDenyResultOnLostResetParkTableOrCommandAck() {
    for (stuck, result): (UInt64, VirtBootFenceResult) in [
      (0x2000_0014, .drainFailed), (0x40_1001_0004, .drainFailed),
      (0x0905_0080, .tableFailed), (0x0905_0020, .syncFailed),
    ] {
      var b = Firmware()
      b.stuck = stuck
      XCTAssertEqual(b.fence(), result)
      if result == .drainFailed { XCTAssertFalse(b.published) }
    }
    var b = Firmware()
    b.synced = false
    XCTAssertEqual(b.fence(), .syncFailed)
    XCTAssertEqual(b.read32(0x0905_0024), 8)
    XCTAssertEqual(b.read32(0x0905_0044), 0x10_1000)
  }
  func testOnlyWritesGlobalAbortAndCanReadBackAgain() {
    var bus = Bus()
    XCTAssertEqual(requestColdVirtPCIAbort(registers: &bus), .pciAbortAcknowledged)
    XCTAssertEqual(requestColdVirtPCIAbort(registers: &bus), .pciAbortAcknowledged)
    XCTAssertEqual(bus.writes, [0x0905_0044])
  }
  func testRejectsOtherRequestersActiveUnitAndFaultsBeforeWriting() {
    for (p, v, result): (UInt64, UInt32, ColdVirtPCIResult) in [
      (0x080a_0000, 3, .unsupportedPlatform), (0x0a00_3e08, 4, .unsupportedPlatform),
      (0x40_100f_f000, 0x1042_1af4, .unexpectedPCI), (0x40_1001_0004, 4, .busMasterActive),
      (0x0905_0020, 1, .smmuInUse), (0x0905_0024, 8, .smmuInUse),
      (0x0905_0044, 1 << 31, .smmuInUse), (0x0905_0054, 4, .smmuInUse),
      (0x0905_0060, 1, .smmuInUse), (0x0905_0fe0, 0, .unsupportedPlatform),
    ] {
      var bus = Bus()
      bus.words[p] = v
      XCTAssertEqual(requestColdVirtPCIAbort(registers: &bus), result)
      XCTAssertTrue(bus.writes.isEmpty)
    }
    var bus = Bus()
    bus.fault = 0x40_1001_1000
    XCTAssertEqual(requestColdVirtPCIAbort(registers: &bus), .unexpectedPCI)
    bus.fwVersion = 3
    XCTAssertEqual(requestColdVirtPCIAbort(registers: &bus), .unsupportedPlatform)
    XCTAssertTrue(bus.writes.isEmpty)
  }
  func testNeverUndoesAbortOnTimeoutIgnoredWriteOrChangedControl() {
    for value: UInt32 in [0x8010_1000, 0, 0x1000, 0x10_1000] {
      var bus = Bus()
      bus.reply = value
      bus.busyAfterWrite = value == 0x10_1000
      XCTAssertEqual(requestColdVirtPCIAbort(registers: &bus), .updateFailed)
      XCTAssertEqual(bus.writes, [0x0905_0044])
    }
  }
}
