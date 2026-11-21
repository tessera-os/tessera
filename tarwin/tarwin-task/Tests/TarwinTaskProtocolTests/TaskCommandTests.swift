import TarwinTaskProtocol
import Testing

@Test func commandWireBytes() {
  let registers = InlineArray<31, UInt64>(repeating: 0x0102_0304_0506_0708)
  let cases: [(TaskCommand, [UInt8])] = [
    (.map(TaskMapping(address: 1, length: 2, offset: 3, protection: 0x0506, copy: true)),
      header(1) + word(1) + word(2) + word(3) + [6, 5, 0, 0, 1, 0, 0, 0]),
    (.protect(address: 4, length: 5, protection: 7), header(2) + word(4) + word(5) + word(7)),
    (.unmap(address: 6, length: 7), header(3) + word(6) + word(7)),
    (.createThread(id: 8, entry: 9, argument: 10, stack: 11, tls: 12),
      header(4) + word(8) + word(9) + word(10) + word(11) + word(12)),
    (.setThreadState(id: 13, state: TaskThreadState(registers: registers, stack: 14, pc: 15, cpsr: 16)),
      header(5) + word(13) + Array(repeating: word(0x0102_0304_0506_0708), count: 31).flatMap { $0 }
        + word(14) + word(15) + word(16)),
    (.suspendThread(id: 17), header(6) + word(17)),
    (.resumeThread(id: 18), header(7) + word(18)),
    (.terminate, header(8)),
  ]
  for (command, expected) in cases {
    var bytes = [UInt8](repeating: 0xff, count: expected.count + 1)
    #expect(bytes.withUnsafeMutableBytes {
      command.encode(into: UnsafeMutableRawBufferPointer(rebasing: $0.dropFirst()))
    })
    #expect(bytes[0] == 0xff)
    #expect(Array(bytes.dropFirst()) == expected)

    let decoded = tryDecode(Array(bytes.dropFirst()))
    #expect(decoded?.opcode == command.opcode)
    #expect(decoded?.opcode.carriesMemoryEntry == (command.opcode == .map))
    var encoded = [UInt8](repeating: 0, count: expected.count)
    #expect(encoded.withUnsafeMutableBytes { decoded?.encode(into: $0) == true })
    #expect(encoded == expected)
  }
}

@Test func rejectsMalformedCommandPayloads() {
  #expect(tryDecode([1, 0, 0, 0, 8, 0, 0]) == nil)
  #expect(tryDecode(header(8) + [0]) == nil)
  #expect(tryDecode([2, 0, 0, 0, 8, 0, 0, 0]) == nil)
  #expect(tryDecode(header(9)) == nil)
  #expect(tryDecode(header(1) + word(1) + word(2) + word(3) + [1, 0, 0, 0, 2, 0, 0, 0]) == nil)
  #expect(tryDecode(header(2) + word(1) + word(2) + [1, 0, 0, 0, 1, 0, 0, 0]) == nil)
}

@Test func signedStatusWireBytes() {
  var bytes = [UInt8](repeating: 0, count: 8)
  #expect(bytes.withUnsafeMutableBytes { TaskCommandReply(status: -2).encode(into: $0) })
  #expect(bytes == [1, 0, 0, 0, 0xfe, 0xff, 0xff, 0xff])
  #expect(bytes.withUnsafeBytes { TaskCommandReply(decoding: $0)?.status } == -2)
  bytes[0] = 2
  #expect(bytes.withUnsafeBytes { TaskCommandReply(decoding: $0) } == nil)
}

private func tryDecode(_ bytes: [UInt8]) -> TaskCommand? {
  bytes.withUnsafeBytes { TaskCommand(decoding: $0) }
}

private func header(_ opcode: UInt8) -> [UInt8] { [1, 0, 0, 0, opcode, 0, 0, 0] }

private func word(_ value: UInt64) -> [UInt8] {
  (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
}
