import TarwinBoot
import Testing

private final class FIFO: TPMFIFORegisters {
  var accessByte: UInt8 = 0x80
  var burst: UInt32 = 3
  var command: [UInt8] = []
  var reply: [UInt8] = []
  var headerLength: UInt8 = 11
  var executions = 0
  var responding = false
  var extra = false
  var available = true
  var requests = 0
  var releases = 0
  func access() -> UInt8 { accessByte }
  func setAccess(_ value: UInt8) {
    if value == 2 {
      requests += 1
      accessByte = 0xa0
    }
    if value == 0x20 {
      releases += 1
      accessByte = 0x80
    }
  }
  func status() -> UInt32 {
    let state: UInt32 =
      responding
      ? (available && !reply.isEmpty ? 0x90 : 0x80)
      : (command.isEmpty ? 0x40 : (command.count == 10 ? 0x80 : 0x88))
    return burst << 8 | state
  }
  func setStatus(_ value: UInt8) {
    if value == 0x40 {
      command = []
      responding = false
    }
    if value == 0x20 {
      executions += 1
      responding = true
      reply = [0x80, 1, 0, 0, 0, headerLength, 0, 0, 0, 0, 42]
      if extra { reply.append(42) }
    }
  }
  func receive() -> UInt8 { reply.removeFirst() }
  func send(_ value: UInt8) { command.append(value) }
}

@Test func burstLimitedFIFOReadsOnlyTheDeclaredReply() throws {
  let io = FIFO()
  var buffer: [UInt8] = [0x80, 1, 0, 0, 0, 10, 0, 0, 0, 0, 0xcc, 0xcc]
  try buffer.withUnsafeMutableBytes {
    var port = try #require(TPMFIFO(registers: io, scratch: $0, pollLimit: 48))
    #expect(port.submit(10) == 11)
    #expect(port.byteAt(10) == 42 && port.byteAt(11) == 0xcc)
    #expect(!port.stopped)
  }
  #expect(io.requests == 1 && io.executions == 1 && io.releases == 1)
}

@Test func ambiguousFIFOFailureNeverExecutesTwice() throws {
  for variant in 0..<5 {
    let io = FIFO()
    switch variant {
    case 0: io.available = false
    case 1: io.headerLength = 9
    case 2: io.headerLength = 255
    case 3: io.extra = true
    default: io.burst = 0
    }
    var buffer: [UInt8] = [0x80, 1, 0, 0, 0, 10, 0, 0, 0, 0, 0, 0]
    try buffer.withUnsafeMutableBytes {
      var port = try #require(TPMFIFO(registers: io, scratch: $0, pollLimit: 64))
      #expect(port.submit(10) == 0)
      #expect(port.stopped)
      #expect(port.submit(10) == 0)
    }
    #expect(io.releases == 1 && io.executions == (variant == 4 ? 0 : 1))
  }
}
