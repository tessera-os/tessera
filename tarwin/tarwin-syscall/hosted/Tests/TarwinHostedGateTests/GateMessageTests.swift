import TarwinABI
import TarwinHostedGate
import Testing

@Test func requestWireRegisterOrder() throws {
  let request = GateRequest(
    threadID: 0x0102_0304_0506_0708, number: 9, arguments: CallRegisters(10, 11, 12, 13, 14, 15, 16, 17))
  var bytes = [UInt8](repeating: 0xff, count: 89)
  #expect(bytes.withUnsafeMutableBytes {
    request.encode(into: UnsafeMutableRawBufferPointer(rebasing: $0.dropFirst()))
  })
  let expected: [UInt8] = [1, 0, 0, 0, 0, 0, 0, 0, 8, 7, 6, 5, 4, 3, 2, 1]
    + (9...17).flatMap { word(UInt8($0)) }
  #expect(bytes[0] == 0xff)
  #expect(Array(bytes.dropFirst()) == expected)
  let decoded = try #require(bytes.withUnsafeBytes {
    GateRequest(decoding: UnsafeRawBufferPointer(rebasing: $0.dropFirst()))
  })
  #expect(decoded.threadID == request.threadID)
  #expect(decoded.number == 9)
  #expect((0..<8).map { decoded.arguments[$0] } == (10...17).map(UInt64.init))
}

@Test func replyWireRegisterOrder() throws {
  let reply = GateReply(result: CallResult(status: 0x0000_0003_0000_0002, detail: 4, first: 5, second: 6))
  var bytes = [UInt8](repeating: 0xff, count: 40)
  #expect(bytes.withUnsafeMutableBytes { reply.encode(into: $0) })
  let expected: [UInt8] = [1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0]
    + (4...6).flatMap { word(UInt8($0)) }
  #expect(bytes == expected)
  let decoded = try #require(bytes.withUnsafeBytes { GateReply(decoding: $0) })
  #expect(decoded.result.code == 2)
  #expect(decoded.result.subsystem == 3)
  #expect(decoded.result.detail == 4)
  #expect(decoded.result.first == 5)
  #expect(decoded.result.second == 6)
}

@Test func rejectsBadVersionReservedBitsAndLength() {
  var bytes = [UInt8](repeating: 0, count: 88)
  #expect(bytes.withUnsafeBytes { GateRequest(decoding: $0) } == nil)
  bytes[0] = 1
  bytes[4] = 1
  #expect(bytes.withUnsafeBytes { GateRequest(decoding: $0) } == nil)
  bytes[4] = 0
  #expect(bytes.withUnsafeBytes {
    GateRequest(decoding: UnsafeRawBufferPointer(rebasing: $0.dropLast()))
  } == nil)
  #expect(bytes.withUnsafeBytes { GateReply(decoding: $0) } == nil)
}

private func word(_ lowByte: UInt8) -> [UInt8] { [lowByte, 0, 0, 0, 0, 0, 0, 0] }
