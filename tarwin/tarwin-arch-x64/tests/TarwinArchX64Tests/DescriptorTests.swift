import TarwinArchX64
import Testing

@Test func descriptorTests() {
  #expect(x64UserPage(0x3000, paBits: 48, write: true, execute: false) == 0x8000_0000_0000_3007)
  #expect(x64UserPage(0x3000, paBits: 48, write: false, execute: true) == 0x3005)
  #expect(x64UserPage(4095, paBits: 48, write: true, execute: false) == 0)
  #expect(x64UserPage(0, paBits: 48, write: true, execute: true) == 0)
  #expect(x64UserPage(UInt64(1) << 40, paBits: 40, write: false, execute: true) == 0)
  #expect(x64WalkIndex(0x1ff000, levelFromLeaf: 0, la57: false) == 511)
  #expect(x64WalkIndex(UInt64(1) << 48, levelFromLeaf: 4, la57: true) == 1)
}
