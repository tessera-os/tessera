// Device address intervals use a base and length, never a wrapping end.
public struct DeviceRange: Equatable {
  public let base: UInt64
  public let length: UInt64

  public func valid() -> Bool {
    if length == 0 { return false }
    return length - 1 <= 0xffff_ffff_ffff_ffff - base
  }

  public func contains(_ child: DeviceRange) -> Bool {
    if !valid() || !child.valid() || child.base < base { return false }
    let offset = child.base - base
    return offset < length && child.length <= length - offset
  }

  public func overlaps(_ other: DeviceRange) -> Bool {
    if !valid() || !other.valid() { return false }
    if base <= other.base { return other.base - base < length }
    return base - other.base < other.length
  }

  public init(base: UInt64, length: UInt64) {
    self.base = base
    self.length = length
  }
}

public func deviceAligned(_ value: UInt64, _ alignment: UInt64) -> Bool {
  if alignment == 0 { return false }
  let mask = alignment - 1
  return (alignment & mask) == 0 && (value & mask) == 0
}
