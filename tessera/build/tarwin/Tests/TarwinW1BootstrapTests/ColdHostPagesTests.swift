import TarwinArchAarch64
import TarwinTime
import Testing
@testable import TarwinW1Bootstrap

@Test(arguments: [UInt64(0), 1, 0x445566, .max])
func unpublishedColdHostMapsOnlyItsStacksAndSharedClock(_ draw: UInt64) {
  let total = W1ColdHostPages.bytes, tableBytes = W1ColdHostPages.tableBytes, page = 16384
  let pa: UInt64 = 0x880000, user = pa - UInt64(4 * page)
  let backing = UnsafeMutableRawBufferPointer.allocate(byteCount: total + page, alignment: page)
  let child = UnsafeMutableRawBufferPointer.allocate(byteCount: 4 * page, alignment: page)
  defer { backing.deallocate(); child.deallocate() }
  backing.initializeMemory(as: UInt8.self, repeating: 0xa5)
  func make(_ physical: UInt64, _ prior: Range<UInt64>, length: Int = W1ColdHostPages.bytes) -> W1ColdHostPages? {
    W1ColdHostPages(backing: .init(rebasing: backing[..<length]), physical: physical,
      privateAllocation: prior, draw: draw)
  }
  for (p, before, n) in [(pa, user..<pa + 1, total), (pa, pa..<pa, total),
    (pa + 1, user..<pa + 1, total), (pa, user..<pa, total - 1)] {
    let rejected = make(p, before, length: n) == nil
    #expect(rejected && backing.allSatisfy { $0 == 0xa5 })
  }
  guard let host = make(pa, user..<pa),
    var lower = ArmUserTranslation(backing: child, physical: user, layout: .guarded),
    host.clock.install(in: &lower, privatePool: user..<pa) else { Issue.record(); return }
  let lo = W1ColdHostPages.controlBase(draw: draw), page64 = UInt64(page)
  #expect(lo == 0xffff_a000_0000_0000 + (draw % (1 << 23)) * 0x20000)
  #expect(host.stacks.root == pa && host.stacks.outgoing == (lo + page64)..<(lo + 3 * page64))
  #expect(host.stacks.scheduler == (lo + 4 * page64)..<(lo + 6 * page64))
  #expect(backing[tableBytes..<total].allSatisfy { $0 == 0 })
  #expect(backing[total...].allSatisfy { $0 == 0xa5 })
  func descriptor(_ memory: UnsafeMutableRawBufferPointer, base: UInt64, va: UInt64) -> UInt64 {
    var offset = 0
    for level in 0..<4 {
      let cell = offset + Int(armWalkIndex(va, level: UInt8(level))) * 8
      guard cell >= 0, cell <= memory.count - 8 else { return .max }
      let word = memory.load(fromByteOffset: cell, as: UInt64.self)
      if word == 0 || level == 3 { return word }
      guard word >= base + 3, word - 3 - base < UInt64(memory.count) else { return .max }
      offset = Int(word - 3 - base)
    }
    return .max
  }
  for i: UInt64 in 0..<8 {
    let word = descriptor(backing, base: pa, va: lo + i * page64)
    if i == 0 || i == 3 || i == 7 { #expect(word == 0) }
    else {
      let frame = pa + UInt64(tableBytes) + (i < 3 ? i - 1 : i - 2) * page64
      #expect(word == frame | 0x703 | (1 << 53) | (1 << 54))
    }
  }
  let clock = pa + UInt64(tableBytes + 4 * page), va = TimePageReader.address47
  #expect(descriptor(child, base: user, va: va) ==
    armUserPage(clock, write: false, execute: false, lpa2: false) | (1 << 51))
  #expect(descriptor(child, base: user, va: va - page64) == 0)
  #expect(descriptor(child, base: user, va: va + page64) == 0)
}
