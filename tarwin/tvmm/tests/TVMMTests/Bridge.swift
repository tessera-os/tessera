import Testing

@testable import TVMM

private final class Backend: VirtioPCIBackend {
  let ram = GuestAperture(base: 0, length: 1 << 16)
  var pins: [Int] = [], kicks: [Int] = [], messages: [UInt64] = [], lines: [Bool] = []
  var resetCount = 0, busy = false, busMaster = false
  func pin(queue: Int, layout: SplitQueueLayout) -> Bool {
    pins.append(queue)
    return true
  }
  func reset() -> Bool {
    resetCount += 1
    return true
  }
  func setBusMaster(_ enabled: Bool) -> Bool {
    if busy && !enabled { return false }
    busMaster = enabled
    return true
  }
  func kick(queue: Int, layout: SplitQueueLayout) -> Bool {
    kicks.append(queue)
    return busMaster
  }
  func readConfig(offset: Int, width: Int) -> UInt64? {
    guard offset + width <= 8 else { return nil }
    return 0x1234_5678_9abc_def0 >> (offset * 8)
  }
  func writeConfig(offset: Int, width: Int, value: UInt64) -> Bool { false }
  func inject(message: UInt64, data: UInt32) -> Bool {
    guard message == 0xfee0_0000 else { return false }
    messages.append(UInt64(data))
    return true
  }
  func setINTx(asserted: Bool) { lines.append(asserted) }
}

private struct Machine {
  let b = Backend()
  let bridge = VirtioPCIBridge(aperture: .init(base: 0xc000_0000, length: 1 << 24))!
  let fn: VirtioPCIFunction
  let ecam: UInt64 = 3 << 15, base: UInt64 = 0xc000_0000
  init() throws {
    fn = try #require(
      VirtioPCIFunction(
        device: 2, classCode: 0x010000, features: 1 << 32,
        queues: [8, 8], vectors: 3, configLength: 8, backend: b))
    try #require(bridge.install(fn, slot: 3))
  }
  func cfg(_ o: Int, _ w: Int) -> UInt64? { bridge.configRead(offset: ecam + UInt64(o), width: w) }
  func set(_ o: Int, _ w: Int, _ v: UInt64) -> Bool {
    bridge.configWrite(offset: ecam + UInt64(o), width: w, value: v)
  }
  func get(_ o: Int, _ w: Int) -> UInt64? { bridge.read(address: base + UInt64(o), width: w) }
  func put(_ o: Int, _ w: Int, _ v: UInt64) -> Bool {
    bridge.write(address: base + UInt64(o), width: w, value: v)
  }
  func enable() throws {
    try #require(set(16, 4, base) && set(4, 2, 6))
    try #require(put(20, 1, 1) && put(20, 1, 3) && put(8, 4, 1) && put(12, 4, 1))
    try #require(put(20, 1, 11) && put(22, 2, 1) && put(32, 8, 0x100))
    try #require(put(40, 8, 0x200) && put(48, 8, 0x300) && put(28, 2, 1) && put(20, 1, 15))
  }
}

@Test func enumerateModernFunctionAndSizeItsGuestBAR() throws {
  let m = try Machine()
  #expect(m.bridge.configRead(offset: 0, width: 4) == 0xffff_ffff)
  #expect(m.bridge.configRead(offset: m.ecam + 4096, width: 2) == 0xffff)
  #expect(m.cfg(0, 4) == 0x1042_1af4 && m.cfg(8, 4) == 0x0100_0001)
  #expect(m.set(0, 4, 0) && m.cfg(0, 4) == 0x1042_1af4)
  var at = Int(try #require(m.cfg(0x34, 1)))
  var kinds = [UInt64]()
  var visited = Set<Int>()
  while at != 0 {
    try #require(visited.insert(at).inserted && at >= 64 && at <= 252 && at % 4 == 0)
    if m.cfg(at, 1) == 9 { kinds.append(try #require(m.cfg(at + 3, 1))) }
    at = Int(try #require(m.cfg(at + 1, 1)))
  }
  #expect(kinds == [1, 2, 3, 4, 5] && visited.count == 7)
  #expect(m.set(16, 4, 0xffff_ffff) && m.cfg(16, 4) == 0xffff_c000)
  #expect(m.set(16, 4, m.base + 123) && m.cfg(16, 4) == m.base)
  #expect(m.get(256, 4) == nil)
  #expect(m.set(4, 2, 2) && m.get(256, 4) == 0x9abc_def0)
  #expect(m.get(263, 2) == nil && m.get(264, 1) == nil)
  #expect(m.set(0x88, 1, 0) && m.set(0x8c, 4, 260) && m.set(0x90, 4, 4))
  #expect(m.cfg(0x94, 4) == 0x1234_5678)
  #expect(m.set(0x88, 1, 1) && m.cfg(0x94, 4) == nil)
  #expect(m.set(0x88, 1, 0) && m.set(0x8c, 4, 261) && m.cfg(0x94, 4) == nil)
  let other = try Machine()
  #expect(m.bridge.install(other.fn, slot: 4))
  #expect(!m.bridge.install(other.fn, slot: 5))
  #expect(m.bridge.configWrite(offset: (4 << 15) + 16, width: 4, value: m.base))
  #expect(m.bridge.configWrite(offset: (4 << 15) + 4, width: 2, value: 2))
  #expect(m.get(256, 4) == nil)
  #expect(m.set(16, 4, 0x8000_0000) && m.bridge.read(address: 0x8000_0100, width: 4) == nil)
}

@Test func kicksRequireBusMasterAndUseNegotiatedQueue() throws {
  let m = try Machine()
  try m.enable()
  #expect(m.b.pins == [1])
  #expect(!m.put(4096, 2, 1) && !m.put(4100, 4, 1) && m.put(4100, 2, 1))
  m.b.busy = true
  #expect(!m.set(4, 2, 2) && m.cfg(4, 2) == 6)
  m.b.busy = false
  #expect(m.set(4, 2, 2) && !m.put(4100, 2, 1))
  #expect(m.b.kicks == [1] && m.set(4, 2, 6))
  #expect(m.fn.queueInterrupt(1) && m.b.lines.last == true)
  #expect(m.fn.configChanged() && m.get(64, 1) == 3 && m.b.lines.last == false)
  #expect(m.get(64, 1) == 0 && m.get(21, 1) == 1)
  // Indirect writes use the same status/reset path as direct MMIO.
  #expect(m.set(0x8c, 4, 20) && m.set(0x90, 4, 1) && m.set(0x94, 1, 0))
  #expect(m.b.resetCount == 1 && !m.put(4100, 2, 1))
}

@Test func guestSelectsMSIOrMSIXAndDrainsPendingThroughItsBAR() throws {
  let m = try Machine()
  try m.enable()
  #expect(m.set(0xa8, 4, 0xfee0_0000) && m.set(0xb0, 2, 42) && m.set(0xa6, 2, 1))
  #expect(m.fn.queueInterrupt(1) && m.b.messages == [42] && m.get(64, 1) == 1)
  #expect(!m.set(0x9a, 2, 0x8000))
  #expect(m.set(0xa6, 2, 0) && m.set(0x9a, 2, 0x8000))
  #expect(!m.set(0xa6, 2, 1))
  let table = Int(try #require(m.cfg(0x9c, 4)))
  let pending = Int(try #require(m.cfg(0xa0, 4)))
  #expect(m.put(26, 2, 2) && m.put(table + 32, 8, 0xfee0_0000) && m.put(table + 40, 4, 99))
  #expect(m.fn.queueInterrupt(1) && m.get(pending, 8) == 4 && m.b.messages == [42])
  #expect(!m.put(pending, 4, 0) && m.get(64, 1) == 0)
  #expect(m.put(table + 44, 4, 0) && m.get(pending, 4) == 0 && m.b.messages == [42, 99])
  #expect(m.put(26, 2, 65535) && m.fn.queueInterrupt(1) && m.b.messages.count == 2)
}
