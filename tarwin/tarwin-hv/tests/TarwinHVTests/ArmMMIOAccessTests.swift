import Testing

@testable import TarwinHV

@Test func armMMIORequiresScalarTranslationFaultInsideRegisteredAperture() {
  let esr: UInt64 = 0x9386_8047  // STR (word) X6, L3 fault
  let far: UInt64 = 0xff00_0070
  let hpfar: UInt64 = 0x5_43210
  let ipa: UInt64 = 0x5432_1070
  let access = ArmMMIOAccess(esr: esr, far: far, hpfar: hpfar, registered: { $0 == ipa && $1 == 4 })
  #expect(access?.exit(readGPR: { $0 == 6 ? UInt64.max : 0 }).data == 0xffff_ffff)
  for bit: UInt64 in [7, 8, 9, 10, 13, 14, 21, 24, 25] {
    #expect(
      ArmMMIOAccess(esr: esr ^ (1 << bit), far: far, hpfar: hpfar, registered: { _, _ in true })
        == nil)
  }
  #expect(ArmMMIOAccess(esr: esr | 8, far: far, hpfar: hpfar, registered: { _, _ in true }) == nil)
  #expect(ArmMMIOAccess(esr: esr, far: far, hpfar: hpfar, registered: { _, _ in false }) == nil)
  #expect(ArmMMIOAccess(esr: esr, far: far + 1, hpfar: hpfar, registered: { _, _ in true }) == nil)
}

@Test func armMMIOCompletesOnlyTargetWidthAndNeverWritesXZR() {
  let esr: UInt64 = 0x9323_0007  // LDRSB W3 -> 32-bit destination
  func load(_ syndrome: UInt64) -> UInt64 {
    var result: UInt64 = 0x1234
    let op = ArmMMIOAccess(esr: syndrome, far: 0, hpfar: 0, registered: { _, _ in true })
    op?.completeLoad(0x1ff, writeGPR: { _, value in result = value })
    return result
  }
  #expect(load(esr) == 0xffff_ffff)
  #expect(load(esr | 0x8000) == UInt64.max)
  #expect(load(esr | (31 << 16)) == 0x1234)
}
