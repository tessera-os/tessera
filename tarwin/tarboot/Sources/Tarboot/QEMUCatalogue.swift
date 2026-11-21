/// Serialized read-only fw_cfg transactions. Implementations translate the
/// selector to bus byte order; reads advance by exactly one byte.
public protocol QEMUConfigReader {
  mutating func select(_ key: UInt16)
  mutating func readByte() -> UInt8
}

/// Read once into private RAM. Return the actual count; transports that
/// report short reads must never retry, pad, or claim full delivery.
public protocol QEMUFileReader: QEMUConfigReader {
  mutating func readSelected(into output: UnsafeMutableRawBufferPointer) -> Int
}

func matchesQEMUName(_ bytes: UnsafeBufferPointer<UInt8>, _ name: StaticString) -> Bool {
  guard bytes.count == name.utf8CodeUnitCount else { return false }
  for i in bytes.indices where bytes[i] != name.utf8Start[i] { return false }
  return true
}

func inventoryQEMUFiles<R: QEMUConfigReader>(
  _ r: inout R, visit: (UInt16, UInt32, UnsafeBufferPointer<UInt8>) -> Bool
) -> Bool {
  func word(_ n: Int) -> UInt32 {
    var v: UInt32 = 0
    for _ in 0..<n { v = v << 8 | UInt32(r.readByte()) }
    return v
  }
  r.select(0)
  guard word(4) == 0x5145_4d55 else { return false }
  r.select(0x19)
  let count = word(4)
  guard count > 0, count <= 4096 else { return false }
  // Fixed stack storage, including on hosts predating InlineArray.
  let four = (UInt64(0), UInt64(0), UInt64(0), UInt64(0))
  let row = (four, four, four, four)
  let group = (row, row, row, row)
  var selectors = (group, group, group, group)
  var field = (four, four)
  return withUnsafeMutableBytes(of: &selectors) { seen in
    withUnsafeMutableBytes(of: &field) { name in
      for _ in 0..<count {
        let size = word(4), key = UInt16(word(2))
        guard word(2) == 0, key >= 0x20, key < 0x4000 else { return false }
        let at = Int(key >> 3), bit = UInt8(1) << (key & 7)
        guard seen[at] & bit == 0 else { return false }
        seen[at] |= bit
        var end = 56
        for i in 0..<56 {
          let b = r.readByte()
          name[i] = b
          if b == 0 && end == 56 { end = i }
        }
        guard end > 0, end < 56, visit(key, size, .init(rebasing: name.bindMemory(to: UInt8.self)[..<end])) else { return false }
      }
      return true
    }
  }
}

/// Search the entire directory before selecting any payload. The returned
/// bytes are untrusted even if the file name and length match exactly.
public func copyQEMUFile<R: QEMUFileReader>(
  _ r: inout R, named name: StaticString, sizes: ClosedRange<Int>,
  into output: UnsafeMutableRawBufferPointer
) -> UnsafeRawBufferPointer? {
  var selected: UInt16?, n = 0
  guard inventoryQEMUFiles(&r, visit: { key, size, file in
    guard matchesQEMUName(file, name) else { return true }
    guard selected == nil, size > 0, let length = Int(exactly: size),
      sizes.contains(length), length <= output.count else { return false }
    selected = key
    n = length
    return true
  }), let selected else { return nil }
  let bytes = UnsafeMutableRawBufferPointer(rebasing: output[..<n])
  r.select(selected)
  guard r.readSelected(into: bytes) == n else { return nil }
  return UnsafeRawBufferPointer(bytes)
}
