import TarwinMM
import Testing

private func withPool(size: Int, epoch: UInt64, limit: Int = 3,
  _ body: (inout ReadQueuePinPool, UnsafeMutableRawBufferPointer) -> Void) {
  let ram = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * size, alignment: size)
  defer { ram.deallocate() }
  ram.initializeMemory(as: UInt8.self, repeating: 0xd3)
  var counters = Array(repeating: UInt32(0), count: 64)
  counters.withUnsafeMutableBufferPointer {
    let leaf = makeArena(UInt64(size) * 64, pageSize: UInt64(size), usable: .max)
    guard let pages = MonitoredPageArena(fresh: leaf, counts: $0, threshold: 0),
      var pool = ReadQueuePinPool(pages: consume pages, mapped: ram, group: 4, epoch: epoch,
        limitPages: limit) else { Issue.record("expected a fresh pin pool"); return }
    body(&pool, ram)
  }
}

@Test(arguments: [4096, 16384])
func chargesAndClearsOnlyThePinnedFrames(_ size: Int) {
  withPool(size: size, epoch: 1) { pool, ram in
    guard var command = pool.take(order: 0, use: .submission),
      var data = pool.take(order: 1, use: .destination) else { Issue.record(); return }
    #expect(command.held && command.bytes == UInt64(size) && command.group == 4 && command.epoch == 1)
    #expect(data.physical == command.physical + UInt64(size * 2) && data.bytes == UInt64(size * 2))
    #expect(pool.chargedPages == 3)
    let overBudget = pool.take(order: 0, use: .completion) == nil
    #expect(overBudget)
    #expect(ram[..<size].allSatisfy { $0 == 0 } && ram[size..<size * 2].allSatisfy { $0 == 0xd3 })
    #expect(ram[size * 2..<size * 4].allSatisfy { $0 == 0 } && ram[size * 4] == 0xd3)
    ram[0] = 0xee
    for epoch: UInt64 in [1, 2] {
      withPool(size: size, epoch: epoch) { other, _ in
        #expect(other.releaseRetired(&command) == false)
      }
    }
    #expect(command.held && pool.chargedPages == 3 && ram[0] == 0xee)
    pool.beginRetirement()
    let dataRetired = pool.releaseRetired(&data)
    #expect(dataRetired)
    let sealed = pool.take(order: 1, use: .completion) == nil
    #expect(sealed && pool.chargedPages == 1 && command.held)
    #expect(pool.releaseRetired(&data) == false)
    let commandRetired = pool.releaseRetired(&command)
    #expect(commandRetired)
    #expect(!command.held && pool.chargedPages == 0 && ram[0] == 0)
  }
}

@Test func pinsStayChargedAndUntouchedOnFatalError() {
  withPool(size: 4096, epoch: 3) { pool, ram in
    guard var pin = pool.take(order: 0, use: .completion) else { Issue.record(); return }
    ram[0] = 42
    #expect(pool.uncorrectable(at: pin.physical) == .kernelPanic)
    pool.beginRetirement()
    #expect(pool.releaseRetired(&pin) == false)
    let refused = pool.take(order: 0, use: .destination) == nil
    #expect(refused && pin.held && pool.chargedPages == 1 && ram[0] == 42)
  }
}

@Test func requiresAnEmptyLeafAndSeparateCounters() {
  let size = 4096, span = 64 * size
  let ram = UnsafeMutableRawBufferPointer.allocate(byteCount: span + size, alignment: size)
  defer { ram.deallocate() }
  var counters = Array(repeating: UInt32(0), count: 64)
  counters.withUnsafeMutableBufferPointer { privateCounts in
    func accepts(_ mapped: UnsafeMutableRawBufferPointer, epoch: UInt64 = 1, limit: Int = 64,
      counts: UnsafeMutableBufferPointer<UInt32>, busy: Bool = false) -> Bool {
      let leaf = makeArena(0x40_0000, pageSize: UInt64(size), usable: .max)
      guard var arena = MonitoredPageArena(fresh: leaf, counts: counts, threshold: 1) else { return false }
      if busy { _ = arena.take(order: 0) }
      return ReadQueuePinPool(pages: consume arena, mapped: mapped, group: 2, epoch: epoch,
        limitPages: limit) != nil
    }
    let full = UnsafeMutableRawBufferPointer(rebasing: ram[..<span])
    #expect(accepts(full, counts: privateCounts))
    #expect(!accepts(full, epoch: 0, counts: privateCounts))
    #expect(!accepts(full, limit: 65, counts: privateCounts))
    #expect(!accepts(full, counts: privateCounts, busy: true))
    #expect(!accepts(.init(rebasing: ram[1...span]), counts: privateCounts))
    #expect(!accepts(.init(rebasing: full[..<(span - 1)]), counts: privateCounts))
    let overlap = UnsafeMutableRawBufferPointer(rebasing: ram[span - 4..<span - 4 + 256])
    #expect(!accepts(full, counts: overlap.bindMemory(to: UInt32.self)))
  }
}
