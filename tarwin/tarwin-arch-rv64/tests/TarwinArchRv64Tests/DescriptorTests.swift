import TarwinArchRv64
import Testing

@Test func descriptorTests() {
  #expect(rvUserPage(0x3000, write: true, execute: false) == 0xc17)
  #expect(rvUserPage(0x3000, write: false, execute: true) == 0xc1b)
  #expect(rvUserPage(1, write: true, execute: false) == 0)
  #expect(rvUserPage(0, write: true, execute: true) == 0)
  #expect(rvUserPage(UInt64(1) << 56, write: false, execute: false) == 0)
  #expect(rvWalkIndex(0x3fe0_0000, levelFromLeaf: 1, sv57: false) == 511)
  #expect(rvWalkIndex(0, levelFromLeaf: 4, sv57: false) == 512)
}
