import TarwinBoot
import Testing

private func madt(_ records: [UInt8]) -> [UInt8] {
  var table = Array(repeating: UInt8(0), count: 44) + records
  table.replaceSubrange(0..<4, with: "APIC".utf8)
  for i in 0..<4 { table[4 + i] = UInt8(truncatingIfNeeded: table.count >> (8 * i)) }
  table[8] = 5
  table[9] = 0 &- table.reduce(0, &+)
  return table
}

private func ids(_ data: [UInt8], _ family: ProcessorFamily, capacity: Int = 4) -> [UInt64]? {
  var ids = Array(repeating: FirmwareProcessor.empty, count: capacity)
  return ids.withUnsafeMutableBufferPointer {
    guard let n = madtProcessors(HostBytes(data), family: family, into: $0) else { return nil }
    return $0.prefix(n).map { $0.hardwareID }
  }
}

@Test func apicIDsBoundsAndAliases() {
  let local: [UInt8] = [0, 8, 7, 11, 1, 0, 0, 0]
  let extended: [UInt8] = [9, 16, 0, 0, 2, 1, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]
  let disabled: [UInt8] = [0, 8, 0, 0, 2, 0, 0, 0]
  let unknown: [UInt8] = [128, 2]
  let records = extended + disabled + unknown + local
  let good = madt(records)
  #expect(ids(good, .x64) == [258, 11])
  #expect(ids(good, .x64, capacity: 1) == nil)
  #expect(ids(good, .arm64) == nil)
  for p in 0..<good.count { #expect(ids(Array(good.prefix(p)), .x64) == nil) }
  for suffix: [UInt8] in [
    local, [0, 8, 7, 12, 1, 0, 0, 0], [0, 8, 2, 11, 1, 0, 0, 0],
    [0, 8, 3, 255, 1, 0, 0, 0], [63], [63, 0], [0, 2],
  ] {
    #expect(ids(madt(records + suffix), .x64) == nil)
  }
  var corrupt = good
  corrupt[9] ^= 1
  #expect(ids(corrupt, .x64) == nil && ids(madt(disabled), .x64) == nil)
}

@Test func armAffinitiesAndRiscvHartIDs() {
  var gic = Array(repeating: UInt8(0), count: 80)
  gic[0] = 11
  gic[1] = 80
  gic[12] = 1
  gic[68] = 5
  gic[72] = 3
  #expect(ids(madt(gic), .arm64) == [0x03_00000005])
  gic[71] = 1
  #expect(ids(madt(gic), .arm64) == nil)
  var rintc = Array(repeating: UInt8(0), count: 36)
  rintc[0] = 24
  rintc[1] = 36
  rintc[2] = 1
  rintc[4] = 1
  rintc[14] = 3
  #expect(ids(madt(rintc), .rv64) == [3 << 48])
  rintc[2] = 2
  #expect(ids(madt(rintc), .rv64) == nil)
}
