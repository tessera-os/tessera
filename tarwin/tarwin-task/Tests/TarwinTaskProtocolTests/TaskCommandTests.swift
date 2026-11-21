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
    (.snapshot(address: 19, size: 20), header(9) + word(19) + word(20)),
    (.threadIdentity(id: 21), header(10) + word(21)),
    (.readMemory(address: 22, size: 3), header(11) + word(22) + word(3)),
    (.readMemory(address: 22, size: 257), header(11) + word(22) + word(257)),
    (.writeMemory(address: 23, data: .inline(([4, 5, 6] as [UInt8]).withUnsafeBytes { TaskMemoryBytes($0)! })),
      header(12) + word(23) + word(3) + [4, 5, 6, 0]),
    (.writeMemory(address: 23, data: .staged(size: 257)), header(12) + word(23) + word(257)),
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
  #expect(tryDecode(header(11) + word(22) + word(3))?.carriesMemoryEntry == false)
  #expect(tryDecode(header(11) + word(22) + word(257))?.carriesMemoryEntry == true)
  #expect(tryDecode(header(12) + word(23) + word(3) + [4, 5, 6, 0])?.carriesMemoryEntry == false)
  #expect(tryDecode(header(12) + word(23) + word(257))?.carriesMemoryEntry == true)
}

@Test func rejectsMalformedCommandPayloads() {
  #expect(tryDecode([1, 0, 0, 0, 8, 0, 0]) == nil)
  #expect(tryDecode(header(8) + [0]) == nil)
  #expect(tryDecode([2, 0, 0, 0, 8, 0, 0, 0]) == nil)
  #expect(tryDecode(header(9)) == nil)
  #expect(tryDecode(header(1) + word(1) + word(2) + word(3) + [1, 0, 0, 0, 2, 0, 0, 0]) == nil)
  #expect(tryDecode(header(2) + word(1) + word(2) + [1, 0, 0, 0, 1, 0, 0, 0]) == nil)
  #expect(tryDecode(header(11) + word(1) + word(0)) == nil)
  #expect(tryDecode(header(11) + word(1) + word(TaskMemoryTransfer.maximumSize + 1)) == nil)
  #expect(tryDecode(header(12) + word(1) + word(3)) == nil)
  #expect(tryDecode(header(12) + word(1) + word(3) + [1, 2, 3, 4]) == nil)
}

@Test func signedStatusWireBytes() {
  var bytes = [UInt8](repeating: 0, count: 8)
  #expect(bytes.withUnsafeMutableBytes { TaskCommandReply(status: -2).encode(into: $0) })
  #expect(bytes == [1, 0, 0, 0, 0xfe, 0xff, 0xff, 0xff])
  #expect(bytes.withUnsafeBytes { TaskCommandReply(decoding: $0)?.status } == -2)
  bytes[0] = 2
  #expect(bytes.withUnsafeBytes { TaskCommandReply(decoding: $0) } == nil)
}

@Test func threadIdentityReplyWireBytes() {
  let identity: UInt64 = 0x0102_0304_0506_0708
  let reply = TaskCommandReply(status: 0, kernelThreadID: identity)
  var bytes = [UInt8](repeating: 0, count: reply.payloadByteCount)
  #expect(bytes.withUnsafeMutableBytes { reply.encode(into: $0) })
  #expect(bytes == header(0) + word(identity))
  #expect(bytes.withUnsafeBytes { TaskCommandReply(decoding: $0)?.kernelThreadID } == identity)
  #expect((header(0) + word(0)).withUnsafeBytes { TaskCommandReply(decoding: $0) } == nil)
  #expect((header(1) + word(identity)).withUnsafeBytes { TaskCommandReply(decoding: $0) } == nil)
}

@Test func liveReadReplyWireBytes() {
  let original: [UInt8] = [4, 5, 6]
  let reply = TaskCommandReply(status: 0, data: original.withUnsafeBytes { TaskMemoryBytes($0) })
  var bytes = [UInt8](repeating: 0xff, count: reply.payloadByteCount)
  #expect(bytes.withUnsafeMutableBytes { reply.encode(into: $0) })
  #expect(bytes == header(0) + word(3) + original + [0])
  let data = bytes.withUnsafeBytes { TaskCommandReply(decoding: $0)?.data }
  #expect(data?.withBytes { Array($0) } == original)
  bytes[19] = 1
  #expect(bytes.withUnsafeBytes { TaskCommandReply(decoding: $0) } == nil)
}

private func tryDecode(_ bytes: [UInt8]) -> TaskCommand? {
  bytes.withUnsafeBytes { TaskCommand(decoding: $0) }
}

private func header(_ opcode: UInt8) -> [UInt8] { [1, 0, 0, 0, opcode, 0, 0, 0] }

private func word(_ value: UInt64) -> [UInt8] {
  (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
}
