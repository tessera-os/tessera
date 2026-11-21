// Bounded, caller-owned storage. Implementations keep the accessible extent
// stable throughout a borrow. Kernel callers must pin mappings before use.
public protocol ByteSource {
  func byteCount() -> UInt64
  func byteAt(_ offset: UInt64) -> UInt8
}

public protocol ByteBuffer: ByteSource {
  mutating func putByte(_ offset: UInt64, value: UInt8)
}
