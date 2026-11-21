import Testing

@testable import TVMM

private final class RAM: PinnedQueueMemory {
  var bytes = Array(repeating: UInt8(0), count: 4096)
  var writes: [UInt64] = []
  func load16Acquire(_ g: UInt64) -> UInt16 { UInt16(vword(bytes, Int(g), 2)) }
  func put(_ g: UInt64, _ v: UInt64, _ width: Int) {
    for n in 0..<width { bytes[Int(g) + n] = UInt8(truncatingIfNeeded: v >> (n * 8)) }
  }
  func store16Release(_ g: UInt64, _ v: UInt16) {
    writes.append(g)
    put(g, UInt64(v), 2)
  }
  func store32(_ g: UInt64, _ v: UInt32) {
    writes.append(g)
    put(g, UInt64(v), 4)
  }
  func read(_ g: UInt64, count: Int) -> [UInt8] { Array(bytes[Int(g)..<(Int(g) + count)]) }
  var fences = 0
  var onFence: (() -> Void)?
  func beforeNotificationCheck() {
    fences += 1
    onFence?()
  }
}

@Test func pciKickCompletesBlockReadAndPublishesThenInterrupts() throws {
  let aperture = GuestAperture(base: 0, length: 4096)
  let m = RAM()
  var bus = try #require(PCICommon(features: 1 << 32, sizes: [8, 8], vectors: 3))
  var pins = 0
  func write(_ offset: Int, _ width: Int, _ val: UInt64) -> Bool {
    bus.write(
      offset: offset, width: width, value: val, ram: aperture,
      pin: { _, _ in
        pins += 1
        return true
      }, reset: { true })
  }
  #expect(write(20, 1, 1))
  #expect(write(20, 1, 3))
  #expect(write(0, 4, 1))
  #expect(bus.read(offset: 4, width: 4) == 1)
  #expect(write(8, 4, 1))
  #expect(write(12, 4, 1))
  #expect(write(20, 1, 11))
  #expect(write(24, 2, 4))
  #expect(write(32, 4, 32))
  #expect(write(36, 4, 0))
  #expect(write(40, 8, 64))
  #expect(write(48, 8, 256))
  #expect(!write(28, 2, 1))
  #expect(pins == 0)  // descriptor/available overlap
  #expect(write(40, 8, 128))
  #expect(write(28, 2, 1))
  #expect(pins == 1)
  #expect(!write(48, 8, 512))
  #expect(write(20, 1, 15))
  let config = BlockFeatures(
    capacity: 1, readOnly: true, flush: false, discard: false,
    zero: false, maxRanges: 0, maxSectors: 0, unmapZeroes: false)
  // First descriptor: read header (sector zero); second: 512-byte block and status.
  m.put(32, 512, 8)
  m.put(40, 16, 4)
  m.put(44, 1, 2)
  m.put(46, 1, 2)
  m.put(48, 1024, 8)
  m.put(56, 513, 4)
  m.put(60, 2, 2)
  m.put(130, 1, 2)
  var pump = QueuePump(slots: 4)
  var interrupts = 0
  let done = bus.notify(slot: 0, queue: 0) { _, q in
    pump.notify(
      q, in: aperture, eventIndex: false, memory: m,
      transfer: { segments in
        guard let command = gatherDeviceRequest(segments, { m.bytes[Int($0)] }),
          let reply = executeBlock(
            command, 513, config, { _, n in Array(repeating: 77, count: Int(n)) },
            { _, _ in false }, { false }, { _, _ in false }),
          scatterDeviceReply(segments, reply, { m.bytes[Int($0)] = $1 })
        else { return nil }
        return UInt64(reply.count)
      },
      interrupt: {
        #expect(m.load16Acquire(258) == 1 && m.fences == 1)
        interrupts += 1
      }) == .progress
  }
  #expect(done && interrupts == 1)
  #expect(m.writes == [260, 264, 258])
  #expect(vword(m.bytes, 264, 4) == 513 && m.bytes[1024] == 77 && m.bytes[1536] == 0)
  #expect(!bus.notify(slot: 1, queue: 0, service: { _, _ in true }))
  #expect(write(20, 1, 0))
  #expect(!bus.notify(slot: 0, queue: 0, service: { _, _ in true }))
}

@Test func maskedMessagesCoalesceAndFailedInjectionRetainsPending() throws {
  var msix = try #require(GuestMSIX(count: 65))
  var messages: [UInt32] = []
  func accept(_ address: UInt64, _ data: UInt32) -> Bool {
    #expect(address == 0x1_fee01000)
    messages.append(data)
    return true
  }
  let offset = 64 * 16
  #expect(msix.writeTable(offset: offset, value: 0xfee0_1000, inject: accept) == true)
  #expect(msix.writeTable(offset: offset + 4, value: 1, inject: accept) == true)
  #expect(msix.writeTable(offset: offset + 8, value: 33, inject: accept) == true)
  #expect(msix.control(enable: true, mask: true, inject: accept) == true)
  #expect(msix.signal(64, inject: accept) == true)
  #expect(msix.signal(64, inject: accept) == true)
  #expect(msix.control(enable: true, mask: false, inject: accept) == true)
  #expect(messages.isEmpty && msix.readPending(word: 1) == 1)
  #expect(msix.writeTable(offset: offset + 12, value: 0, inject: { _, _ in false }) == false)
  #expect(msix.readPending(word: 1) == 1)
  #expect(msix.control(enable: true, mask: false, inject: accept) == true)
  #expect(msix.readPending(word: 1) == 0 && messages == [33])
}

@Test func eventIndexPublishesKickThresholdAndRechecksAfterArming() throws {
  let ram = GuestAperture(base: 0, length: 4096)
  let m = RAM()
  var bus = try #require(PCICommon(features: (1 << 32) | (1 << 29), sizes: [2], vectors: 0))
  func put(_ offset: Int, _ width: Int, _ value: UInt64) -> Bool {
    bus.write(
      offset: offset, width: width, value: value, ram: ram,
      pin: { _, _ in true }, reset: { true })
  }
  #expect(put(20, 1, 1))
  #expect(put(20, 1, 3))
  #expect(put(12, 4, 1 << 29))
  #expect(put(8, 4, 1))
  #expect(put(12, 4, 1))
  #expect(put(20, 1, 11))
  #expect(put(40, 8, 32))
  #expect(put(48, 8, 64))
  #expect(put(28, 2, 1))
  #expect(put(20, 1, 15))
  var pump = QueuePump(slots: 2)
  var interrupts = 0
  func kick() -> PumpResult {
    pump.notify(
      bus.queues[0], in: ram, eventIndex: true, memory: m, transfer: { _ in 0 },
      interrupt: { interrupts += 1 })
  }
  // Driver publishes while the device is enabling kicks.
  m.onFence = { if m.fences == 1 { m.put(34, 1, 2) } }
  #expect(kick() == .reschedule)
  #expect(kick() == .progress)
  #expect(m.load16Acquire(84) == 1 && interrupts == 1)
  #expect(kick() == .drained)
}
