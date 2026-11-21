import TarwinArchAarch64
import Testing

@Test func buildsPrivateTablesWithoutPartialUpdatesOrWritableCode() {
  let storage = UnsafeMutableRawBufferPointer.allocate(byteCount: 4 * 16384, alignment: 16)
  defer { storage.deallocate() }
  let root: UInt64 = 0x80000
  guard var t = ArmUserTranslation(backing: storage, physical: root) else {
    Issue.record("failed to open owned arena")
    return
  }
  func insert(_ virtual: UInt64, _ physical: UInt64, write: Bool, execute: Bool) -> Bool {
    t.insert(virtual: virtual, physical: physical, write: write, execute: execute)
  }
  let va: UInt64 = 1 << 32
  #expect(insert(va, 0x40000, write: false, execute: true))
  #expect(t.usedPages == 4)
  let words = storage.bindMemory(to: UInt64.self)
  #expect(words[0] == root + 16384 + 3)
  #expect(words[2048] == root + 32768 + 3)
  #expect(words[4096 + 128] == root + 49152 + 3)
  #expect(words[6144] == armUserPage(0x40000, write: false, execute: true, lpa2: false) | (1 << 50))
  let before = Array(words)
  #expect(!insert(va, 0x40000, write: true, execute: false))
  #expect(!insert(va + 16384, root, write: true, execute: false))
  #expect(!insert(va + 16384, 0x44000, write: true, execute: true))
  #expect(!insert(1 << 38, 0x44000, write: true, execute: false))
  #expect(!insert(1 << 48, 0x44000, write: true, execute: false))
  #expect(!insert(va + 1, 0x44000, write: false, execute: false))
  #expect(Array(words) == before)
  #expect(insert(va + 16384, 0x44000, write: true, execute: false))
  #expect(words[6145] == armUserPage(0x44000, write: true, execute: false, lpa2: false))
}
