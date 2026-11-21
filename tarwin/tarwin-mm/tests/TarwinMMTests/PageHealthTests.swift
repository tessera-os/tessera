import TarwinMM
import Testing

@Test func retiresOnlyTheAffectedPageOfAnActiveBlock() {
  for size: UInt64 in [4096, 16384] {
    var slots = Array(repeating: UInt32.max, count: 64)
    slots.withUnsafeMutableBufferPointer { counts in
      let base = size * 64, target = base + size * 3
      guard var pages = MonitoredPageArena(fresh: makeArena(base, pageSize: size, usable: .max),
        counts: counts, threshold: 1) else { Issue.record("fresh arena refused"); return }
      let all = pages.take(order: 6)
      #expect(all.ok && all.address == base)
      #expect(pages.corrected(at: target + 8) == .counted)
      #expect(pages.corrected(at: target + size) == .counted)
      #expect(pages.corrected(at: target + size - 1) == .evacuate)
      #expect(pages.correctedCount(at: target) == 2)
      #expect(pages.give(address: target, order: 0) == false)
      #expect(pages.give(address: base, order: 6) == true)
      #expect(pages.take(order: 6).ok == false)
      var got = Set<UInt64>()
      for _ in 0..<63 {
        let one = pages.take(order: 0)
        #expect(one.ok && one.address != target)
        got.insert(one.address)
      }
      #expect(got.count == 63)
      #expect(pages.take(order: 0).ok == false)
    }
  }
}

@Test func fatalErrorsConsultOwnersOnlyForManagedAllocatedFrames() {
  var slots = Array(repeating: UInt32(0), count: 64)
  slots.withUnsafeMutableBufferPointer { counts in
    let base: UInt64 = 0x10_0000, size: UInt64 = 4096
    guard var pages = MonitoredPageArena(fresh: makeArena(base, pageSize: size, usable: 6),
      counts: counts, threshold: 0) else { Issue.record(); return }
    for address in [base - 1, base, base + size * 64, .max] {
      #expect(pages.corrected(at: address) == .notManaged)
      #expect(pages.uncorrectable(at: address, use: { _ in Issue.record(); return .kernelOrUnknown }) == .notManaged)
    }
    let one = pages.take(order: 0)
    #expect(one.ok && one.address == base + size)
    #expect(pages.uncorrectable(at: base + 2 * size, use: { _ in Issue.record(); return .kernelOrUnknown }) == .retiredFree)
    let action = pages.uncorrectable(at: one.address + 1) { p in
      #expect(p == one.address); return .userMappingsOnly
    }
    #expect(action == .terminateUserMappings)
    #expect(pages.corrected(at: one.address) == .alreadyPoisoned)
    #expect(pages.uncorrectable(at: one.address, use: { _ in .kernelOrUnknown }) == .kernelPanic)
    #expect(pages.give(address: one.address, order: 0) == true)
    #expect(pages.take(order: 0).ok == false)
  }
}
