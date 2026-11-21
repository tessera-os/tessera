import KCore

/// UEFI 2.10 §4.2. Only the declared prefix of a pinned firmware table is covered.
public func validFirmwareTable<S: ByteSource>(
  _ table: S, signature: UInt64, minimumSize: UInt64
) -> Bool {
  guard table.byteCount() >= 24, minimumSize >= 24,
    little(table, at: 0, bytes: 8) == signature, little(table, at: 20, bytes: 4) == 0
  else { return false }
  let size = little(table, at: 12, bytes: 4)
  guard size >= minimumSize, size <= table.byteCount() else { return false }
  var crc = UInt32.max
  for i in 0..<size {
    if !(16..<20).contains(i) { crc ^= UInt32(table.byteAt(i)) }
    for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1 == 0) ? 0 : 0xedb8_8320) }
  }
  return ~crc == UInt32(little(table, at: 16, bytes: 4))
}

/// The original firmware attributes and type remain available for runtime mappings.
/// Loader-owned allocations stay reserved until identified and released by their owner.
public struct FirmwareRegion {
  public let base: UInt64
  public let length: UInt64
  public let type: UInt32
  public let attributes: UInt64

  public static var empty: Self { Self(base: 0, length: 0, type: 0, attributes: 0) }

  public func bootMapKind(afterExit: Bool) -> UInt32 {
    switch type {
    case 5: return 2  // runtime code
    case 6: return 3  // runtime data
    default: break
    }
    guard attributes >> 63 == 0 else { return 1 }  // includes runtime MMIO
    switch type {
    case 3, 4: return afterExit ? 0 : 1
    case 7: return 0
    case 8: return 10
    case 9: return 4
    case 10: return 5
    case 14: return 6
    default: return 1
    }
  }
}

private func sift(
  _ regions: inout UnsafeMutableBufferPointer<FirmwareRegion>, root: Int, end: Int
) {
  var i = root
  while i < end / 2 {
    var child = 2 * i + 1
    if child + 1 < end && regions[child].base < regions[child + 1].base { child += 1 }
    if regions[i].base >= regions[child].base { return }
    regions.swapAt(i, child)
    i = child
  }
}

/// UEFI §7.2.3. The input is immutable through validation; the caller lends a disjoint,
/// initialized scratch buffer. Discard scratch on failure. No pointers into firmware
/// descriptors escape. A successful result is still only a snapshot, not ownership of RAM.
@unsafe public func stageFirmwareMap<S: ByteSource>(
  _ bytes: S, stride: UInt64, version: UInt32,
  into regions: inout UnsafeMutableBufferPointer<FirmwareRegion>
) -> Int? {
  let length = bytes.byteCount()
  guard version == 1, stride >= 40, length > 0, length % stride == 0,
    length / stride <= UInt64(regions.count)
  else { return nil }
  let n = Int(length / stride)
  for i in 0..<n {
    let offset = UInt64(i) * stride
    let base = little(bytes, at: offset + 8, bytes: 8)
    let pages = little(bytes, at: offset + 24, bytes: 8)
    guard base & 4095 == 0, pages != 0, pages <= (UInt64.max - base) >> 12
    else { return nil }
    regions[i] = FirmwareRegion(
      base: base, length: pages << 12,
      type: UInt32(little(bytes, at: offset, bytes: 4)),
      attributes: little(bytes, at: offset + 32, bytes: 8))
  }
  if n > 1 {
    var i = n / 2
    while i > 0 {
      i -= 1
      sift(&regions, root: i, end: n)
    }
    var end = n
    while end > 1 {
      end -= 1
      regions.swapAt(0, end)
      sift(&regions, root: 0, end: end)
    }
    for j in 1..<n where regions[j - 1].base + regions[j - 1].length > regions[j].base {
      return nil
    }
  }
  return n
}
