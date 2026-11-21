// Train-private panic format: commit byte, version, two reserved bytes, length
// and CRC32 (little endian); payload TLVs: kind:u8, size:u32, bytes. The writer
// can only address the reserved region through the composition-provided accessors.
public enum PanicLayout {
  public static let header: UInt64 = 12
  public static let maxBytes: UInt64 = 1_048_576
  public static let committed: UInt8 = 0xa5
}
func crcByte(_ initial: UInt32, _ byte: UInt8) -> UInt32 {
  var v = initial ^ UInt32(byte)
  var i: UInt64 = 0
  while i < 8 {
    v = (v & 1) == 0 ? v >> 1 : (v >> 1) ^ 0xedb8_8320
    i += 1
  }
  return v
}
public struct PanicWriter {
  public let capacity: UInt64
  public internal(set) var cursor: UInt64 = 0
  public internal(set) var crc: UInt32 = 0xffff_ffff
  public internal(set) var sealed: Bool = false

  public init(capacity: UInt64) {
    self.capacity = capacity
  }

  public mutating func begin(_ put: (UInt64, UInt8) -> Void, _ persist: () -> Void) -> Bool {
    if capacity < PanicLayout.header { return false }
    put(0, 0)
    persist()
    put(1, 1)
    put(2, 0)
    put(3, 0)
    cursor = PanicLayout.header
    crc = 0xffff_ffff
    sealed = false
    return true
  }
  public mutating func byte(_ data: UInt8, _ put: (UInt64, UInt8) -> Void) {
    put(cursor, data)
    crc = crcByte(crc, data)
    cursor += 1
  }
  public mutating func section(
    _ kind: UInt8, _ length: UInt64, _ get: (UInt64) -> UInt8,
    _ put: (UInt64, UInt8) -> Void
  ) -> Bool {
    let limit = capacity > PanicLayout.maxBytes ? PanicLayout.maxBytes : capacity
    if sealed || cursor < PanicLayout.header || cursor > limit || limit - cursor < 5
      || length > limit - cursor - 5 || kind == 0
    {
      return false
    }
    byte(kind, put)
    var i: UInt64 = 0
    while i < 4 {
      byte(UInt8((length >> (i * 8)) & 255), put)
      i += 1
    }
    i = 0
    while i < length {
      byte(get(i), put)
      i += 1
    }
    return true
  }
  public mutating func commit(_ put: (UInt64, UInt8) -> Void, _ persist: () -> Void) -> Bool {
    if cursor <= PanicLayout.header || sealed { return false }
    let digest = UInt64(crc ^ 0xffff_ffff)
    var i: UInt64 = 0
    while i < 4 {
      put(4 + i, UInt8((cursor >> (i * 8)) & 255))
      put(8 + i, UInt8((digest >> (i * 8)) & 255))
      i += 1
    }
    persist()
    put(0, PanicLayout.committed)
    persist()
    sealed = true
    return true
  }
}

public func panicSize(_ capacity: UInt64, _ get: (UInt64) -> UInt8) -> UInt64 {
  if capacity < PanicLayout.header || get(0) != PanicLayout.committed || get(1) != 1
    || get(2) != 0 || get(3) != 0
  {
    return 0
  }
  var length: UInt64 = 0
  var expected: UInt64 = 0
  var i: UInt64 = 0
  while i < 4 {
    length = length | (UInt64(get(4 + i)) << (i * 8))
    expected = expected | (UInt64(get(8 + i)) << (i * 8))
    i += 1
  }
  if length <= PanicLayout.header || length > capacity || length > PanicLayout.maxBytes { return 0 }
  var crc: UInt32 = 0xffff_ffff
  i = PanicLayout.header
  while i < length {
    crc = crcByte(crc, get(i))
    i += 1
  }
  if UInt64(crc ^ 0xffff_ffff) != expected { return 0 }
  i = PanicLayout.header
  while i < length {
    if length - i < 5 || get(i) == 0 { return 0 }
    var n: UInt64 = 0
    var j: UInt64 = 0
    while j < 4 {
      n = n | (UInt64(get(i + 1 + j)) << (j * 8))
      j += 1
    }
    i += 5
    if n > length - i { return 0 }
    i += n
  }
  return length
}
