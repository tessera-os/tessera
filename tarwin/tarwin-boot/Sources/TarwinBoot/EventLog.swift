/// Bounded TCG PC Client crypto-agile log. The first record has the legacy
/// layout and describes the digest banks of the following Event2 records.
public struct EventLogFormat {
  private let banks: UInt32
  public let firstEvent: Int

  private static func bank(_ id: UInt16) -> (mask: UInt32, size: Int)? {
    switch id {
    case 4: return (1, 20)
    case 11: return (2, 32)
    case 12: return (4, 48)
    case 13: return (8, 64)
    case 18: return (16, 32)
    default: return nil
    }
  }

  public init?(_ log: UnsafeRawBufferPointer) {
    guard log.count >= 61, u32(log, 0) == 0, u32(log, 4) == 3 else { return nil }
    for i in 8..<28 where log[i] != 0 { return nil }
    let sig: StaticString = "Spec ID Event03"
    for i in 0..<15 where log[32 + i] != sig.utf8Start[i] { return nil }
    guard log[47] == 0, log[52] == 0, log[53] == 2, log[55] == 1 || log[55] == 2 else { return nil }
    let count = Int(u32(log, 56))
    let n = Int(u32(log, 28))
    guard (1...5).contains(count), n <= log.count - 32, 29 + 4 * count <= n else { return nil }
    var known: UInt32 = 0
    for i in 0..<count {
      let p = 60 + 4 * i
      guard let b = Self.bank(u16(log, p)), b.size == Int(u16(log, p + 2)), known & b.mask == 0
      else { return nil }
      known |= b.mask
    }
    guard known & 2 != 0, n == 29 + 4 * count + Int(log[60 + 4 * count]) else { return nil }
    banks = known
    firstEvent = 32 + n
  }

  public struct Entry {
    public let pcr: UInt32
    public let type: UInt32
    public let sha256: Int
    public let payload: Range<Int>
  }

  public func event(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> Entry? {
    guard offset >= 0, bytes.count >= 12, offset <= bytes.count - 12 else { return nil }
    let pcr = u32(bytes, offset)
    let type = u32(bytes, offset + 4)
    let count = u32(bytes, offset + 8)
    guard pcr < 24, count == banks.nonzeroBitCount else { return nil }
    var idx = offset + 12
    var seen: UInt32 = 0
    var sha = 0
    for _ in 0..<count {
      guard idx <= bytes.count - 2, let b = Self.bank(u16(bytes, idx)), banks & b.mask != 0,
        seen & b.mask == 0, b.size <= bytes.count - idx - 2
      else { return nil }
      seen |= b.mask
      if b.mask == 2 { sha = idx + 2 }
      idx += 2 + b.size
    }
    guard seen == banks, idx <= bytes.count - 4 else { return nil }
    let size = Int(u32(bytes, idx))
    idx += 4
    guard size <= bytes.count - idx else { return nil }
    return Entry(pcr: pcr, type: type, sha256: sha, payload: idx..<idx + size)
  }

  /// GetEventLog's last pointer is the start, not the end, of the final record.
  public func primaryLength(_ bytes: UnsafeRawBufferPointer, last: Int) -> Int? {
    var i = firstEvent
    while i <= last {
      guard let e = event(bytes, at: i) else { return nil }
      if i == last { return e.payload.upperBound }
      i = e.payload.upperBound
    }
    return nil
  }

  /// The final table includes records from before this loader's GetEventLog if
  /// an earlier firmware component queried it. Skip only an exact record-aligned
  /// suffix of the captured primary bytes; refuse ambiguity rather than replay twice.
  public func finalSuffix(
    _ final: UnsafeRawBufferPointer, baseline: UInt64,
    primary: UnsafeRawBufferPointer
  ) -> Range<Int>? {
    guard final.count >= 16, u64(final, 0) == 1 else { return nil }
    let total = u64(final, 8)
    guard baseline <= total, total <= UInt64((final.count - 16) / 12) else { return nil }
    var pos = 16
    var skip = 16
    for id in 0..<total {
      guard let e = event(final, at: pos) else { return nil }
      pos = e.payload.upperBound
      if id < baseline { skip = pos }
    }
    if baseline != 0 {
      guard primary.count >= firstEvent, skip - 16 <= primary.count - firstEvent else { return nil }
      let suffix = primary.count - (skip - 16)
      var i = firstEvent
      while i < suffix {
        guard let e = event(primary, at: i) else { return nil }
        i = e.payload.upperBound
      }
      guard i == suffix else { return nil }
      for j in 16..<skip where primary[suffix + (j - 16)] != final[j] { return nil }
    }
    return skip..<pos
  }
}

private func u16(_ b: UnsafeRawBufferPointer, _ i: Int) -> UInt16 {
  UInt16(littleEndian: b.loadUnaligned(fromByteOffset: i, as: UInt16.self))
}
private func u32(_ b: UnsafeRawBufferPointer, _ i: Int) -> UInt32 {
  UInt32(littleEndian: b.loadUnaligned(fromByteOffset: i, as: UInt32.self))
}
private func u64(_ b: UnsafeRawBufferPointer, _ i: Int) -> UInt64 {
  UInt64(littleEndian: b.loadUnaligned(fromByteOffset: i, as: UInt64.self))
}
