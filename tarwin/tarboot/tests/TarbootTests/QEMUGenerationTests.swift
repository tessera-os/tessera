@testable import Tarboot
import Testing

private struct Config: QEMUConfigReader {
  let directory: [UInt8]
  var signature = Array("QEMU".utf8)
  var files: [UInt16: [UInt8]] = [:]
  var selected: UInt16 = .max
  var offset = 0
  mutating func select(_ key: UInt16) { selected = key; offset = 0 }
  mutating func readByte() -> UInt8 {
    let data = selected == 0 ? signature : (selected == 0x19 ? directory : files[selected] ?? [])
    defer { offset += 1 }
    return offset < data.count ? data[offset] : 0
  }
}

private func entry(_ name: String, _ size: UInt16, _ key: UInt8) -> [UInt8] {
    let n = Array(name.utf8)
    return [0, 0, UInt8(size >> 8), UInt8(truncatingIfNeeded: size), 0, key, 0, 0]
      + n + Array(repeating: 0, count: 56 - n.count)
}
@Test func catalogueCannotSupplyAnEpochOrPartiallyAdvertiseTheDevice() {
  let addr = entry("etc/vmgenid_addr", 8, 32)
  let guid = entry("etc/vmgenid_guid", 4096, 33)
  let other = entry("etc/acpi/tables", 16, 34)
  var good = Config(directory: [0, 0, 0, 3] + other + guid + addr)
  guard case .advertised(32, 33) = qemuGenerationDevice(&good) else {
    Issue.record("valid pair not inventoried"); return
  }
  var absent = Config(directory: [0, 0, 0, 1] + other)
  guard case .unavailable = qemuGenerationDevice(&absent) else { Issue.record("false device"); return }
  for d in [[0, 0, 0, 1] + addr, [0, 0, 0, 2] + guid + guid,
            [0, 0, 0, 2] + addr + entry("etc/vmgenid_guid", 16, 33),
            [0, 0, 0, 2] + addr + entry("etc/vmgenid_guid", 4096, 32),
            [0, 0, 0, 2] + other, [0, 1, 0, 0]] {
    var source = Config(directory: d)
    if case .malformed = qemuGenerationDevice(&source) {} else { Issue.record("accepted bad catalogue") }
  }
}

@Test func discoverOnlyAStableLiveIDInReservedMemory() {
  let directory = [0, 0, 0, 2] as [UInt8]
  var c = Config(directory: directory + entry("etc/vmgenid_addr", 8, 32)
    + entry("etc/vmgenid_guid", 4096, 33))
  let p: UInt64 = 0x8000 + 40
  func le(_ x: UInt64) -> [UInt8] { withUnsafeBytes(of: x.littleEndian) { Array($0) } }
  func region(_ type: UInt32 = 10, _ attr: UInt64 = 8, _ base: UInt64 = 0x8000,
    _ bytes: UInt64 = 4096) -> FirmwareRegion {
    FirmwareRegion(base: base, length: bytes, type: type, attributes: attr)
  }
  var reads = 0
  func discover(_ r: FirmwareRegion, _ addr: UInt64 = 0x8028, _ values: [UInt64?] = [9, 17, 9, 17])
    -> QEMUGenerationPage? {
    c.files[32] = le(addr)
    c.files[33] = [UInt8](repeating: 0, count: 40) + le(9) + le(17)
    reads = 0
    return [r].withUnsafeBufferPointer { rs in
      QEMUGenerationPage.discover(&c, regions: rs) { at in
        defer { reads += 1 }
        guard reads < values.count, at == p + UInt64(reads % 2) * 8 else { return nil }
        return values[reads]
      }
    }
  }
  let result = discover(region())
  #expect(result?.physical == p)
  #expect(result?.sample { $0 == p ? 33 : 44 }?.0 == 33)
  for addr: UInt64 in [0, 40, p + 8, (1 << 32) + 40] {
    #expect(discover(region(), addr) == nil)
    #expect(reads == 0)
  }
  for r in [region(7), region(9), region(10, 0), region(10, 0x2008),
            region(10, 8, 0x9000), region(10, 8, 0x8000, 4095)] {
    #expect(discover(r) == nil)
    #expect(reads == 0)
  }
  for values: [UInt64?] in [[nil], [9, nil], [0, 0], [9, 17, 1], [9, 17, 9, 1], [7, 8, 7, 8]] {
    #expect(discover(region(), p, values) == nil)
  }
}
