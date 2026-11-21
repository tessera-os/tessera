import TarwinArchAarch64
import Testing

@Test func importSlotIsSignedOnlyForMappedTargetAndWholePrivateRELRO() {
  let root = UnsafeMutableRawBufferPointer.allocate(byteCount: 4*16384, alignment: 16)
  let frame = UnsafeMutableRawBufferPointer.allocate(byteCount: 16384, alignment: 16)
  defer { root.deallocate(); frame.deallocate() }
  let base: UInt64 = 1 << 32, page: UInt64 = 16384
  let code = base..<base+12, relro = base+page..<base+2*page, slot = base+page+8
  let modifier = slot | (0xabcd << 48), target = base+8
  frame.initializeMemory(as: UInt8.self, repeating: 0x5a)
  guard var t = ArmUserTranslation(backing: root, physical: 0x80000),
    t.insert(virtual: base, physical: 0x40000, write: false, execute: true),
    t.insert(virtual: base+page, physical: 0x44000, write: true, execute: false)
  else { Issue.record("missing test mappings"); return }
  var calls = 0, allow = false
  func bind(_ r: Range<UInt64>, _ addr: UInt64, _ dest: UInt64, _ mod: UInt64, _ pa: UInt64) -> Bool {
    t.bindPrivateImport(slot: addr, target: dest, modifier: mod, libraryCode: code, relro: r,
      frame: frame, physical: pa, sign: { ptr, mix in
        calls += 1
        return allow && ptr == target && mix == modifier ? 0xfeed : nil
      })
  }
  let before = Array(root), initial = Array(frame)
  #expect(!bind(base+page..<base+3*page, slot, target, modifier, 0x44000))
  #expect(!bind(relro, slot, target, modifier, 0x48000))
  #expect(!bind(relro, slot, base+12, modifier, 0x44000))
  #expect(!bind(relro, slot, target, modifier+8, 0x44000))
  #expect(calls == 0)
  #expect(!bind(relro, slot, target, modifier, 0x44000))
  #expect(calls == 1 && Array(root) == before && Array(frame) == initial)
  allow = true
  #expect(bind(relro, slot, target, modifier, 0x44000))
  #expect(frame.load(fromByteOffset: 8, as: UInt64.self) == 0xfeed)
  #expect(frame[0..<8].allSatisfy { $0 == 0x5a } && frame[16...].allSatisfy { $0 == 0x5a })
  #expect(!bind(relro, slot, target, modifier, 0x44000))
  #expect(calls == 2)
}
