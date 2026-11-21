import Tarboot
import Testing

private struct Config: QEMUConfigReader {
  let directory: [UInt8]
  var signature = Array("QEMU".utf8)
  var selected: UInt16 = .max
  var offset = 0
  mutating func select(_ key: UInt16) { selected = key; offset = 0 }
  mutating func readByte() -> UInt8 {
    let data = selected == 0 ? signature : directory
    defer { offset += 1 }
    return offset < data.count ? data[offset] : 0
  }
}

@Test func catalogueCannotSupplyAnEpochOrPartiallyAdvertiseTheDevice() {
  func entry(_ name: String, _ size: UInt16, _ key: UInt8) -> [UInt8] {
    let n = Array(name.utf8)
    return [0, 0, UInt8(size >> 8), UInt8(truncatingIfNeeded: size), 0, key, 0, 0]
      + n + Array(repeating: 0, count: 56 - n.count)
  }
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
