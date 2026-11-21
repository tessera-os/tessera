// Bounded, caller-owned storage. Implementations keep the accessible extent
// stable throughout a borrow. Kernel callers must pin mappings before use.
public protocol ByteSource {
  func byteCount() -> UInt64
  func byteAt(_ offset: UInt64) -> UInt8
}

public protocol ByteBuffer: ByteSource {
  mutating func putByte(_ offset: UInt64, value: UInt8)
}

/// A fixed-width word within an already checked record in a pinned source.
public func little<S: ByteSource>(_ src: S, at: UInt64, bytes: UInt64) -> UInt64 {
  precondition(bytes <= 8 && at <= src.byteCount() && bytes <= src.byteCount() - at)
  var value: UInt64 = 0
  for i in 0..<bytes { value |= UInt64(src.byteAt(at + i)) << (8 * i) }
  return value
}
