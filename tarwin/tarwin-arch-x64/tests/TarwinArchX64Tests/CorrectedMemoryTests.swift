import TarwinArchX64
import Testing

@Test func attributesOnlyUnambiguousCorrectedPhysicalMemoryReports() {
  let status: UInt64 = 0x9c00_0000_0000_009f
  func page(_ s: UInt64, _ a: UInt64 = 0x1234_5004, _ m: UInt64 = 0x80,
    _ bits: UInt8 = 36) -> UInt64? {
    x64CorrectedMemoryPage(status: s, address: a, misc: m, physicalBits: bits)
  }
  #expect(page(status) == 0x1234_5000)
  #expect(page(status ^ 0x30, 0x1234_5fff, 0x8c) == 0x1234_5000)
  for bit in [63, 62, 61, 60, 59, 58, 57, 56, 55, 38, 16, 8] {
    #expect(page(status ^ (1 << bit)) == nil)
  }
  #expect(page(status, 1 << 36) == nil)
  #expect(page(status, 0, 0) == nil)
  #expect(page(status, 0, 0x8d) == nil)
  #expect(page(status, 0, 0x80, 0) == nil)
}
