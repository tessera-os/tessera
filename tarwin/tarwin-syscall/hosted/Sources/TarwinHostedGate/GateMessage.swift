import TarwinABI

/// The wire format is independent of the Swift layout of the register types.
public struct GateRequest {
  public static let version: UInt32 = 1
  public static let messageID: Int32 = 0x5457_0201
  public static let byteCount = 88

  public let threadID, number: UInt64
  public let arguments: CallRegisters

  public init(threadID: UInt64, number: UInt64, arguments: CallRegisters) {
    self.threadID = threadID
    self.number = number
    self.arguments = arguments
  }

  public init?(decoding bytes: UnsafeRawBufferPointer) {
    guard valid(bytes, count: Self.byteCount) else { return nil }
    threadID = readWord(bytes, at: 8)
    number = readWord(bytes, at: 16)
    var arguments = CallRegisters()
    for i in 0..<8 { arguments[i] = readWord(bytes, at: 24 + 8 * i) }
    self.arguments = arguments
  }

  public func encode(into bytes: UnsafeMutableRawBufferPointer) -> Bool {
    guard bytes.count == Self.byteCount else { return false }
    writeWord(UInt64(Self.version), to: bytes, at: 0)
    writeWord(threadID, to: bytes, at: 8)
    writeWord(number, to: bytes, at: 16)
    for i in 0..<8 { writeWord(arguments[i], to: bytes, at: 24 + 8 * i) }
    return true
  }
}

public struct GateReply {
  public static let messageID: Int32 = 0x5457_0202
  public static let byteCount = 40

  public let result: CallResult

  public init(result: CallResult) { self.result = result }

  public init?(decoding bytes: UnsafeRawBufferPointer) {
    guard valid(bytes, count: Self.byteCount) else { return nil }
    result = CallResult(
      status: readWord(bytes, at: 8), detail: readWord(bytes, at: 16),
      first: readWord(bytes, at: 24), second: readWord(bytes, at: 32))
  }

  public func encode(into bytes: UnsafeMutableRawBufferPointer) -> Bool {
    guard bytes.count == Self.byteCount else { return false }
    writeWord(UInt64(GateRequest.version), to: bytes, at: 0)
    writeWord(result.status, to: bytes, at: 8)
    writeWord(result.detail, to: bytes, at: 16)
    writeWord(result.first, to: bytes, at: 24)
    writeWord(result.second, to: bytes, at: 32)
    return true
  }
}

private func valid(_ bytes: UnsafeRawBufferPointer, count: Int) -> Bool {
  bytes.count == count && readWord(bytes, at: 0) == UInt64(GateRequest.version)
}

private func readWord(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt64 {
  UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
}

private func writeWord(_ word: UInt64, to bytes: UnsafeMutableRawBufferPointer, at offset: Int) {
  for i in 0..<8 { bytes[offset + i] = UInt8(truncatingIfNeeded: word >> (8 * i)) }
}
