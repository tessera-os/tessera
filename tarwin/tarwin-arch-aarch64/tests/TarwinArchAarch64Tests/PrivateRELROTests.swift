import TarwinArchAarch64
import Testing

@Test func privateRELROPreflightsEveryPageIncludingAcrossTables() {
  let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: 5 * 16384, alignment: 16)
  defer { buf.deallocate() }
  guard var t = ArmUserTranslation(backing: buf, physical: 0x80_000) else {
    Issue.record("missing private root"); return
  }
  let page: UInt64 = 16384, second: UInt64 = (1 << 32) + (1 << 25)
  let first = second - page
  let words = buf.bindMemory(to: UInt64.self)
  func insert(_ va: UInt64, _ pa: UInt64, _ w: Bool, _ x: Bool) -> Bool {
    t.insert(virtual: va, physical: pa, write: w, execute: x)
  }
  func seal(_ span: Range<UInt64>) -> Bool { t.sealReadOnly(span) }
  #expect(insert(first, 0x4_0000, true, false))
  #expect(insert(second, 0x4_4000, true, false))
  #expect(insert(second + 2 * page, 0x4_8000, false, true))
  let before = Array(words)
  for bad in [first..<first, first..<second+1, first+1..<second, first..<second+2*page,
              first-page..<second, second+2*page..<second+3*page, 0..<page,
              (1<<47)..<((1<<47)+page)] {
    #expect(!seal(bad))
    #expect(Array(words) == before)
  }
  #expect(seal(first..<second+page))
  var expected = before
  expected[3 * 2048 + 2047] |= 1 << 7
  expected[4 * 2048] |= 1 << 7
  #expect(Array(words) == expected)
  #expect(!seal(first..<second+page))
}
