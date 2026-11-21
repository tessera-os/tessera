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
