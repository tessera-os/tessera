import KCore
import Testing

@Test func rangeTests() {
  #expect(!withinRange(0, length: 0, lower: 0, upper: 32))
  #expect(!withinRange(32, length: 1, lower: 0, upper: 32))
  #expect(withinRange(16, length: 16, lower: 16, upper: 32))
  #expect(!withinRange(15, length: 1, lower: 16, upper: 32))
  #expect(!validExtent(0xffff_ffff_ffff_ffff, length: 1))
  #expect(!isPowerOfTwo(0))
  #expect(alignedTo(0x4000, alignment: 0x4000))
  #expect(!alignedTo(48, alignment: 3))
}
