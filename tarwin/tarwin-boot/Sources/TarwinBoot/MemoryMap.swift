import KCore

public struct PhysicalRegion {
  public internal(set) var base: UInt64
  public internal(set) var length: UInt64
  public internal(set) var kind: UInt32
  public internal(set) var attributes: UInt32

  public init(base: UInt64, length: UInt64, kind: UInt32, attributes: UInt32) {
    self.base = base
    self.length = length
    self.kind = kind
    self.attributes = attributes
  }
}

public func regionByte(_ region: PhysicalRegion, offset: UInt64) -> UInt8 {
  var word: UInt64 = 0
  if offset < 8 {
    word = region.base
  } else if offset < 16 {
    word = region.length
  } else if offset < 24 {
    word = UInt64(region.kind) | (UInt64(region.attributes) << 32)
  }
  return UInt8((word >> ((offset & 7) * 8)) & 255)
}

public struct MapCursor {
  public internal(set) var remaining: UInt64
  public internal(set) var end: UInt64
  public internal(set) var failed: Bool
}

public func beginMemoryMap(_ count: UInt64, available: UInt64) -> MapCursor {
  return MapCursor(remaining: count, end: 0, failed: count == 0 || count > available / 32)
}

// Feed the four little-endian words of each descriptor, in physical order.
// No RAM is released until the entire immutable map has passed this check.
public func acceptRegion(
  _ cursor: inout MapCursor, base: UInt64, length: UInt64, typeAndAttributes: UInt64,
  reserved: UInt64
) -> Bool {
  if cursor.failed || cursor.remaining == 0 || base < cursor.end
    || !validExtent(base, length: length) || (typeAndAttributes & 0xffff_ffff) > 10 || reserved != 0
  {
    cursor.failed = true
    return false
  }
  cursor.end = base + length
  cursor.remaining -= 1
  return true
}

public func completeMemoryMap(_ cursor: MapCursor) -> Bool {
  return !cursor.failed && cursor.remaining == 0
}
