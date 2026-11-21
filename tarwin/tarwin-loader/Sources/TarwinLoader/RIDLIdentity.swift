// KLF-RIDL §24.3. Consume the whole blob even when the requested UUID
// appears early: a truncated import or a second current ABI invalidates it.
struct RIDLIdentity {
  let name: UnsafeRawBufferPointer
  let uuid: UnsafeRawBufferPointer
}

extension WireCursor {
  mutating func metadataString() -> Range<Int>? {
    guard let p = take(4) else { return nil }
    let n = Int(reader.u32(p))
    guard let i = take(n), reader.wireText(i..<(i + n)) else { return nil }
    return i..<(i + n)
  }
}

func bytesMatch(_ lhs: UnsafeRawBufferPointer, _ rhs: UnsafeRawBufferPointer) -> Bool {
  guard lhs.count == rhs.count else { return false }
  for i in lhs.indices where lhs[i] != rhs[i] { return false }
  return true
}

struct RIDLMetadata {
  let bytes: UnsafeRawBufferPointer

  /// W1 uses strict binding: a retired UUID cannot satisfy an early import.
  func supports(_ expected: RIDLIdentity, textSHA256: UnsafeRawBufferPointer? = nil) -> Bool {
    let r = ELFReader(bytes: bytes)
    var c = WireCursor(reader: r, pos: 0, end: bytes.count)
    guard expected.uuid.count == 16, let h = c.take(8), r.u32(h) == 0x4c44_4952,
      r.u16(h + 4) == 1, r.u16(h + 6) == 0, let name = c.metadataString(),
      bytesMatch(.init(rebasing: bytes[name]), expected.name), let n = c.take(4)
    else { return false }
    var current = false
    var found = false
    for _ in 0..<r.u32(n) {
      guard let p = c.take(17), r.u64(p) | r.u64(p + 8) != 0 else { return false }
      let status = bytes[p + 16]
      guard status <= 2, status != 0 || !current else { return false }
      if status == 0 { current = true }
      if bytesMatch(.init(rebasing: bytes[p..<p + 16]), expected.uuid) {
        guard !found, status != 2 else { return false }
        found = true
      }
    }
    guard current, found, let imports = c.take(4) else { return false }
    for _ in 0..<r.u32(imports) {
      guard c.metadataString() != nil, let p = c.take(16), r.u64(p) | r.u64(p + 8) != 0
      else { return false }
    }
    guard let digest = c.take(32), let unmanaged = c.take(4) else { return false }
    if let textSHA256, !bytesMatch(.init(rebasing: bytes[digest..<digest + 32]), textSHA256) {
      return false
    }
    for _ in 0..<r.u32(unmanaged) {
      guard c.metadataString() != nil else { return false }
    }
    return c.pos == c.end
  }
}
