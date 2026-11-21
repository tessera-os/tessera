public enum TaskMemoryTransfer {
  public static let inlineLimit = 256
  public static let maximumSize: UInt64 = 1 << 20

  public static func contains(address: UInt64, size: UInt64) -> Bool {
    address >= TaskWindow.base && address < TaskGatePage.address
      && size != 0 && size <= maximumSize && size <= TaskGatePage.address - address
  }
}

public struct TaskMemoryBytes: Sendable {
  private var storage = InlineArray<256, UInt8>(repeating: 0)
  public let count: Int

  public init?(_ bytes: UnsafeRawBufferPointer) {
    guard (1...TaskMemoryTransfer.inlineLimit).contains(bytes.count) else { return nil }
    count = bytes.count
    withUnsafeMutableBytes(of: &storage) { buffer in
      buffer.baseAddress!.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
    }
  }

  public func withBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) rethrows -> T {
    try withUnsafeBytes(of: storage) { buffer in
      try body(UnsafeRawBufferPointer(start: buffer.baseAddress, count: count))
    }
  }

  static func paddedCount(_ count: Int) -> Int { (count + 3) & ~3 }

  init?(decoding bytes: UnsafeRawBufferPointer, count: UInt64) {
    guard count > 0, count <= TaskMemoryTransfer.inlineLimit,
      bytes.count == Self.paddedCount(Int(count)) else { return nil }
    for index in Int(count)..<bytes.count where bytes[index] != 0 { return nil }
    self.init(UnsafeRawBufferPointer(start: bytes.baseAddress, count: Int(count)))
  }

  func encode(into bytes: UnsafeMutableRawBufferPointer) {
    withBytes { bytes.baseAddress!.copyMemory(from: $0.baseAddress!, byteCount: count) }
    for index in count..<bytes.count { bytes[index] = 0 }
  }
}

public enum TaskMemoryWrite: Sendable {
  case inline(TaskMemoryBytes)
  case staged(size: UInt64)
}
