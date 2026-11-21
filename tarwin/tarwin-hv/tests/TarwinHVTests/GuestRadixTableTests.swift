import Testing

@testable import TarwinHV

@Test func radixTablesCountMissingLevelsAndPreserveWholeExtents() {
  for format: GuestRadixFormat in [.sv48x4, .npt, .ept] {
    let rootFrames = format == .sv48x4 ? 4 : 1
    let pa: UInt64 = 0x4000_0000
    var pages = Array(repeating: UInt64.max, count: (rootFrames + 4) * 512)
    pages.withUnsafeMutableBufferPointer { p in
      var t = GuestRadixTables(format: format, arena: p, physicalBase: pa)!
      let boundary: UInt64 = 1 << 21
      #expect(
        t.install(ipa: boundary - 4096, bytes: 8192, pinnedPA: 0x8000, permissions: 3) == true)
      let expected: UInt64
      switch format {
      case .sv48x4: expected = (0x9000 >> 2) | 0xd7
      case .npt: expected = 0x9007 | (1 << 63)
      case .ept: expected = 0x9033
      }
      #expect(p[(rootFrames + 3) * 512] == expected)
      #expect(t.install(ipa: 1 << 30, bytes: 4096, pinnedPA: 0, permissions: 1) == false)
      #expect(p[rootFrames * 512 + 1] == 0)
      #expect(t.detach(ipa: boundary - 8192, bytes: 12288) == false)
      #expect(p[(rootFrames + 3) * 512] == expected)
      #expect(t.detach(ipa: boundary - 4096, bytes: 8192) == true)
      #expect(t.install(ipa: boundary, bytes: 4096, pinnedPA: pa, permissions: 1) == false)
    }
  }
}

@Test func sv48x4UsesAllElevenRootIndexBits() {
  var storage = Array(repeating: UInt64(0), count: 7 * 512)
  storage.withUnsafeMutableBufferPointer { buf in
    var t = GuestRadixTables(format: .sv48x4, arena: buf, physicalBase: 0)!
    let top = (UInt64(1) << 50) - 4096
    #expect(t.install(ipa: top, bytes: 4096, pinnedPA: 1 << 30, permissions: 5) == true)
    #expect(buf[2047] == 0x1001)
    #expect(buf[511] == 0)
    #expect(t.install(ipa: top, bytes: 8192, pinnedPA: 1 << 30, permissions: 1) == false)
  }
}
