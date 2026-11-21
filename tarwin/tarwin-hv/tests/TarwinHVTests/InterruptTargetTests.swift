import Testing

@testable import TarwinHV

@Test func armVirtualIRQsUseOnlyEmptyImplementedSlots() throws {
  #expect(ArmVirtualIRQ(interrupt: 1020, priority: 0) == nil)
  let irq = try #require(ArmVirtualIRQ(interrupt: 37, priority: 0x80))
  var writes = 0
  for (count, empty) in [(0, UInt64.max), (17, .max), (1, 2), (4, 0)] {
    #expect(
      !irq.inject(count: count, empty: empty) { _, _ in
        writes += 1
        return true
      })
  }
  #expect(
    irq.inject(count: 3, empty: 6) { index, value in
      writes += 1
      return index == 1 && value == 0x5080_0000_0000_0025
    })
  #expect(!irq.inject(count: 1, empty: 1) { _, _ in false })
  #expect(writes == 1)
}

@Test func imsicRequiresOwnedGuestFileAndValidNonzeroIdentity() throws {
  for (base, length, files, index) in [
    (UInt64(1), UInt64(8192), UInt8(1), UInt8(1)),
    (0, 8192, 1, 0), (0, 8192, 1, 2), (0, 8192, 2, 1), (UInt64.max - 4095, 8192, 1, 1),
  ] {
    #expect(
      IMSICGuestTarget(hartBase: base, bytes: length, files: files, index: index, lastID: 63) == nil
    )
  }
  let file = try #require(
    IMSICGuestTarget(hartBase: 0x10000, bytes: 16384, files: 3, index: 2, lastID: 63))
  var writes = 0
  for id: UInt16 in [0, 64] {
    #expect(
      !file.post(id) { _, _ in
        writes += 1
        return true
      })
  }
  #expect(
    file.post(63) { pa, value in
      writes += 1
      return pa == 0x12000 && value == 63
    })
  #expect(!file.post(1) { _, _ in false })
  #expect(writes == 1)
}
