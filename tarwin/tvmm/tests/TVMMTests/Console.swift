import Testing

@testable import TVMM

private final class Port: QueueTestRAM, ConsoleHost {
  let ram = GuestAperture(base: 0, length: 4096)
  var input = [UInt8](), output = [UInt8]()
  var writable = false, pinned = false, line = false
  var waits = [Int](), pins = 0
  func pin(queue: Int, layout: SplitQueueLayout) -> Bool { true }
  func reset() -> Bool {
    waits.removeAll()
    return true
  }
  func setBusMaster(_ enabled: Bool) -> Bool { true }
  func withPinnedPayload(_ spans: [Segment], _ body: () -> QueueTransfer) -> QueueTransfer {
    pins += 1
    pinned = true
    defer { pinned = false }
    return body()
  }
  func readByte(_ address: UInt64) -> UInt8 {
    #expect(pinned)
    return bytes[Int(address)]
  }
  func writeByte(_ address: UInt64, _ value: UInt8) {
    #expect(pinned)
    bytes[Int(address)] = value
  }
  func receive(_ capacity: Int) -> [UInt8] {
    let portion = Array(input.prefix(capacity))
    input.removeFirst(portion.count)
    return portion
  }
  func transmit(_ bytes: [UInt8]) -> Bool {
    guard writable else { return false }
    output += bytes
    return true
  }
  func schedule(queue: Int, waitingForPort: Bool) {
    if waitingForPort { waits.append(queue) }
  }
  func inject(message: UInt64, data: UInt32) -> Bool { false }
  func setINTx(asserted: Bool) { line = asserted }
}

@Test func consoleRejectsOversizeWrappedOrMixedChainsBeforePinning() {
  let host = Port()
  for spans in [
    [Segment(address: 0, length: DeviceIoLimit.bytes + 1, writable: true)],
    [Segment(address: .max, length: 2, writable: true)],
    [
      Segment(address: 0, length: 1, writable: true),
      Segment(address: 1, length: 1, writable: false),
    ],
  ] {
    #expect(VirtioConsole.transfer(queue: 0, segments: spans, host: host) == .invalid)
  }
  #expect(host.pins == 0)
}

@Test func guestConsoleRetainsPostedBuffersUntilTheHostIsReady() throws {
  let host = Port()
  let device = try #require(VirtioConsole(queueSize: 4, vectors: 2, host: host))
  let base: UInt64 = 0xc000_0000
  let bridge = try #require(VirtioPCIBridge(aperture: .init(base: base, length: 1 << 20)))
  try #require(bridge.install(device.function, slot: 0))
  #expect(bridge.configRead(offset: 0, width: 4) == 0x1043_1af4)
  func put(_ at: UInt64, _ width: Int, _ value: UInt64) -> Bool {
    bridge.write(address: base + at, width: width, value: value)
  }
  try #require(bridge.configWrite(offset: 16, width: 4, value: base))
  try #require(bridge.configWrite(offset: 4, width: 2, value: 6))
  try #require(put(20, 1, 1) && put(20, 1, 3) && put(8, 4, 1) && put(12, 4, 1) && put(20, 1, 11))
  for q in UInt64(0)...1 {
    let d = q * 256
    try #require(put(22, 2, q) && put(32, 8, d) && put(40, 8, d + 64))
    try #require(put(48, 8, d + 128) && put(28, 2, 1))
    host.put(d, 1024 + q * 16, 8)
    host.put(d + 8, 4, 4)
    host.put(d + 12, q == 0 ? 2 : 0, 2)
    host.put(d + 66, 1, 2)
  }
  try #require(put(20, 1, 15))
  host.bytes.replaceSubrange(1040..<1044, with: [72, 105, 13, 10])
  #expect(put(4096, 2, 0) && put(4100, 2, 1))
  #expect(host.waits == [0, 1] && !host.line && host.writes.isEmpty)
  host.input = [65, 66]
  host.writable = true
  try #require(bridge.configWrite(offset: 4, width: 2, value: 2))
  device.resume(queue: 0)
  #expect(host.input.count == 2 && host.writes.isEmpty)
  try #require(bridge.configWrite(offset: 4, width: 2, value: 6))
  for queue in 0...1 {
    device.resume(queue: queue)
    device.resume(queue: queue)
  }
  #expect(host.line && bridge.read(address: base + 64, width: 1) == 1 && !host.line)
  #expect(host.bytes[1024..<1028] == [65, 66, 0, 0] && host.output == [72, 105, 13, 10])
  #expect(host.load16Acquire(130) == 1 && vword(host.bytes, 136, 4) == 2)
  #expect(host.load16Acquire(386) == 1 && vword(host.bytes, 392, 4) == 0)
  // New RX head is readable, not writable. Reject without consuming host input.
  host.input = [67]
  host.put(12, 0, 2)
  host.put(66, 2, 2)
  #expect(!put(4096, 2, 0) && host.input == [67] && host.load16Acquire(130) == 1)
  try #require(put(20, 1, 0))
  device.resume(queue: 0)
  #expect(host.input == [67] && host.waits.isEmpty)
}
