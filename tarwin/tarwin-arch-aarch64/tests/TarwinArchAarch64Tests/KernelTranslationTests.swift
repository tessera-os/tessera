import TarwinArchAarch64
import Testing

@Test func upperRootUsesPrivilegedOnlyLeavesAndRejectsInvalidMappings() {
  let arena = UnsafeMutableRawBufferPointer.allocate(byteCount: 4 * 16384, alignment: 16)
  defer { arena.deallocate() }
  let base: UInt64 = 0xffff_8000_0000_0000
  let root: UInt64 = 0x80_000
  guard var tables = ArmKernelTranslation(backing: arena, physical: root) else {
    Issue.record("could not initialize a private root")
    return
  }
  func insert(_ va: UInt64, _ pa: UInt64, _ w: Bool, _ x: Bool) -> Bool {
    tables.insert(virtual: va, physical: pa, write: w, execute: x)
  }
  #expect(insert(base, 0x40000, false, true))
  #expect(insert(base + 16384, 0x44000, true, false))
  #expect(insert(base + 32768, 0x48000, false, false))
  let words = arena.bindMemory(to: UInt64.self)
  #expect(tables.usedPages == 4 && tables.physicalRoot == root)
  #expect(words[0] == 0 && words[1] == root + 16384 + 3)
  #expect(words[6144] == 0x0044_0000_0004_0783)
  #expect(words[6145] == 0x0060_0000_0004_4703)
  #expect(words[6146] == 0x0060_0000_0004_8783)
  let before = Array(words)
  for (va, pa, w, x) in [
    (base, 0x40000 as UInt64, true, false), (base + 49152, root, false, false),
    (base + 49152, 0x4c000, true, true), (base + 49152, 1 << 48, false, false),
    (base + 49152, 0x4c001, false, false), (base + 49153, 0x4c000, false, false),
    (base - 16384, 0x4c000, false, false), (1 << 32, 0x4c000, false, false),
    (base + (1 << 38), 0x4c000, false, false),
  ] {
    #expect(!insert(va, pa, w, x))
  }
  #expect(Array(words) == before)
}
