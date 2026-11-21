import Testing

@testable import TarwinHV

@Test func stageTwoBuildsOnlyPinnedPagesAndChecksWholeExtentBeforeEdits() {
  let granule = ArmStageTwo.pageSize
  let root: UInt64 = 0x4800_0000
  var backing = Array(repeating: UInt64.max, count: 3 * 2048)
  backing.withUnsafeMutableBufferPointer { buf in
    var table = ArmStageTwo(arena: buf, physicalBase: root)!
    let boundary = UInt64(1 << 25)
    #expect(table.install(ipa: 0, bytes: granule, pinnedPA: root, permissions: 3) == false)
    #expect(table.install(ipa: 0, bytes: granule, pinnedPA: 0x100, permissions: 1) == false)
    #expect(
      table.install(
        ipa: ArmStageTwo.ipaLimit - granule, bytes: 2 * granule, pinnedPA: 0, permissions: 1)
        == false)
    #expect(
      table.install(
        ipa: 0, bytes: 2 * granule, pinnedPA: ArmStageTwo.outputLimit - granule, permissions: 1)
        == false)
    #expect(table.install(ipa: 0, bytes: granule, pinnedPA: 0, permissions: 7) == false)
    #expect(table.install(ipa: boundary, bytes: granule, pinnedPA: 0x8000, permissions: 5) == true)
    #expect(
      table.install(ipa: boundary - granule, bytes: 2 * granule, pinnedPA: 0, permissions: 3)
        == false)
    #expect(buf[0] == 0 && buf[1] == root + granule + 3)
    #expect(buf[2048] == 0x877f)
    #expect(table.detach(ipa: boundary, bytes: 2 * granule) == false)
    #expect(buf[2048] == 0x877f)
    #expect(table.detach(ipa: boundary, bytes: granule) == true)
    #expect(
      table.install(ipa: boundary - granule, bytes: 2 * granule, pinnedPA: 0, permissions: 3)
        == true)
    #expect(buf[2048] == (1 << 54) | granule | 0x7ff)
    #expect(buf[6143] == (1 << 54) | 0x7ff)
    #expect(
      table.install(ipa: boundary * 2, bytes: granule, pinnedPA: 0x14000, permissions: 1) == false)
    #expect(buf[2] == 0)
  }
}
