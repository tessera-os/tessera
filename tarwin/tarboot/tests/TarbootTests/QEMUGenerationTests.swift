@testable import Tarboot
import Testing

private struct Config: QEMUFileReader {
  let directory: [UInt8]
  var signature = Array("QEMU".utf8)
  var files: [UInt16: [UInt8]] = [:]
  var selected: UInt16 = .max
  var offset = 0
  var copies = 0
  mutating func select(_ key: UInt16) { selected = key; offset = 0 }
  mutating func readByte() -> UInt8 {
    let data = selected == 0 ? signature : (selected == 0x19 ? directory : files[selected] ?? [])
    defer { offset += 1 }
    return offset < data.count ? data[offset] : 0
  }
  mutating func readSelected(into output: UnsafeMutableRawBufferPointer) -> Int {
    copies += 1
    let n = min(output.count, files[selected]?.count ?? 0)
    for i in 0..<n { output[i] = readByte() }
    return n
  }
}

private func entry(_ name: String, _ size: UInt16, _ key: UInt8) -> [UInt8] {
    let n = Array(name.utf8)
    return [0, 0, UInt8(size >> 8), UInt8(truncatingIfNeeded: size), 0, key, 0, 0]
      + n + Array(repeating: 0, count: 56 - n.count)
}

@Test func payloadCopyRequiresAnUnambiguousDirectoryAndExactTransfer() {
  let name: StaticString = "opt/org.tessera/tarwin/w1.sig"
  let file = entry(name.description, 7, 47)
  let data: [UInt8] = [0, 2, 3, 4, 5, 6, 0]
  func check(_ entries: [[UInt8]], _ payload: [UInt8], _ capacity: Int = 8)
    -> (length: Int?, copies: Int, bytes: [UInt8]) {
    var reader = Config(directory: [0, 0, 0, UInt8(entries.count)] + entries.flatMap { $0 },
      files: [47: payload])
    var bytes = [UInt8](repeating: 0xcc, count: capacity)
    let length = bytes.withUnsafeMutableBytes {
      copyQEMUFile(&reader, named: name, sizes: 1...65536, into: $0)?.count
    }
    return (length, reader.copies, bytes)
  }
  let ok = check([file], data)
  #expect(ok.length == data.count && ok.copies == 1 && ok.bytes == data + [0xcc])
  let short = check([file], Array(data.dropLast()))
  #expect(short.length == nil && short.copies == 1 && short.bytes.last == 0xcc)
  var oversized = file
  oversized[1] = 1
  for directory in [[entry("etc/other", 7, 47)], [file, entry(name.description, 7, 48)],
    [file, entry("etc/alias", 7, 47)], [file, entry("etc/invalid", 1, 2)],
    [entry(name.description, 0, 47)], [oversized]] {
    let result = check(directory, data, 65544)
    #expect(result.length == nil && result.copies == 0)
  }
  let small = check([file], data, 6)
  #expect(small.length == nil && small.copies == 0)
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

@Test func registerABIMustBeUniqueAndCannotCoexistWithACPI() {
  let name = "etc/tarwin/vmgenid-ro", marker = entry(name, 1, 36)
  func scan(_ rows: [[UInt8]], _ abi: UInt8 = 1) -> QEMUGenerationDevice {
    var config = Config(directory: [0, 0, 0, UInt8(rows.count)] + rows.flatMap { $0 },
      files: [36: [abi]])
    return qemuGenerationDevice(&config)
  }
  guard case .readOnlyRegisters = scan([marker]) else { Issue.record("ABI 1 missing"); return }
  for invalid in [scan([marker], 0), scan([marker], 2), scan([entry(name, 8, 36)]),
    scan([marker, entry(name, 1, 37)]), scan([marker, entry("etc/vmgenid_addr", 8, 37)]),
    scan([entry("etc/vmgenid_guid", 4096, 37), marker])] {
    if case .malformed = invalid {} else { Issue.record("accepted invalid register inventory") }
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
  func discover(_ r: FirmwareRegion, _ addr: UInt64 = 0x8028, _ values: [UInt64?] = [9, 17, 9, 17],
    more: [FirmwareRegion] = [], pin: UInt64 = 0x8000)
    -> QEMUGenerationPage? {
    c.files[32] = le(addr)
    c.files[33] = [UInt8](repeating: 0, count: 40) + le(9) + le(17)
    reads = 0
    return ([r] + more).withUnsafeBufferPointer { rs in
      QEMUGenerationPage.discover(&c, pinnedPage: pin, regions: rs) { at in
        defer { reads += 1 }
        guard reads < values.count, at == p + UInt64(reads % 2) * 8 else { return nil }
        return values[reads]
      }
    }
  }
  let result = discover(region())
  #expect(result?.physical == p)
  #expect(result?.sample { $0 == p ? 33 : 44 }?.0 == 33)
  #expect(discover(region(), pin: 0x9000) == nil)
  #expect(reads == 0)
  for other in [region(), region(7), region(7, 8, 0x8fff, 4096), region(7, 8, .max, 4096)] {
    #expect(discover(region(), more: [other]) == nil)
    #expect(reads == 0)
  }
  #expect(discover(region(), more: [region(7, 8, 0x9000)])?.physical == p)
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
