import TarwinArchAarch64
import Testing

@Test func descriptorTests() {
  let rx = armUserPage(0x8000, write: false, execute: true, lpa2: false)
  #expect(rx == 0x0020_0000_0000_8fc3)
  #expect(armUserPage(0x8000, write: true, execute: true, lpa2: false) == 0)
  #expect(armUserPage(1, write: false, execute: false, lpa2: false) == 0)
  #expect(armUserPage(0, write: false, execute: false, lpa2: true) == 0)
  #expect(armWalkIndex(0x3ffc000, level: 3) == 2047)
  #expect(armWalkIndex(0x2000000, level: 2) == 1)
}
