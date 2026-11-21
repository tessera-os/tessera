import KCore

// TIR 29.6. The caller pins an immutable archive throughout checking and use.
// Member offsets describe bytes, not trusted images: verify the platform
// signature and each uncompressed BLAKE3 digest before using any payload.
public struct BootMember {
  public internal(set) var validArchive: Bool
  public internal(set) var found: Bool
  public internal(set) var offset: UInt64
  public internal(set) var stored: UInt64
  public internal(set) var size: UInt64
  public internal(set) var compression: UInt8
  public internal(set) var digestAt: UInt64
}

func emptyMember() -> BootMember {
  return BootMember(
    validArchive: false, found: false, offset: 0, stored: 0, size: 0, compression: 0, digestAt: 0)
}

// Only called with the entire fixed-width record already in bounds.
func little<S: ByteSource>(_ src: S, at: UInt64, bytes: UInt64) -> UInt64 {
  var value: UInt64 = 0
  var i: UInt64 = 0
  while i < bytes {
    value = value | (UInt64(src.byteAt(at + i)) << (8 * i))
    i += 1
  }
  return value
}

func pathLength<S: ByteSource>(_ src: S, pos: inout UInt64) -> UInt64 {
  var n: UInt64 = 0
  var shift: UInt64 = 0
  while shift <= 63 && pos < src.byteCount() {
    let b = src.byteAt(pos)
    pos += 1
    if shift == 63 && b > 1 { return 0 }
    n = n | (UInt64(b & 127) << shift)
    if b < 128 {
      if shift != 0 && b == 0 { return 0 }
      return n
    }
    shift += 7
  }
  return 0
}

func scalarBytes<S: ByteSource>(_ s: S, at: UInt64, end: UInt64) -> UInt64 {
  let b = s.byteAt(at)
  if b < 128 { return 1 }
  if b < 194 || b > 244 { return 0 }
  var n: UInt64 = 2
  if b >= 240 { n = 4 } else if b >= 224 { n = 3 }
  if n > end - at { return 0 }
  let second = s.byteAt(at + 1)
  if (b == 224 && second < 160) || (b == 237 && second >= 160) || (b == 240 && second < 144)
    || (b == 244 && second >= 144)
  {
    return 0
  }
  var i: UInt64 = 1
  while i < n {
    if (s.byteAt(at + i) & 192) != 128 { return 0 }
    i += 1
  }
  return n
}

func componentAllowed<S: ByteSource>(_ s: S, start: UInt64, length: UInt64) -> Bool {
  if length == 0 { return false }
  if s.byteAt(start) != 46 { return true }
  return length != 1 && (length != 2 || s.byteAt(start + 1) != 46)
}

func archivePath<S: ByteSource>(_ s: S, start: UInt64, length: UInt64) -> Bool {
  let end = start + length
  var p = start
  var component = start
  if length >= 2 && s.byteAt(start + 1) == 58 {
    let first = s.byteAt(start) | 32
    if first >= 97 && first <= 122 { return false }
  }
  while p < end {
    let b = s.byteAt(p)
    if b == 0 || b == 92 { return false }
    if b == 47 {
      if !componentAllowed(s, start: component, length: p - component) { return false }
      component = p + 1
    }
    let n = scalarBytes(s, at: p, end: end)
    if n == 0 { return false }
    p += n
  }
  return componentAllowed(s, start: component, length: end - component)
}

func comparePaths<S: ByteSource, T: ByteSource>(
  _ a: S, pa: UInt64, na: UInt64, b: T, pb: UInt64, nb: UInt64
) -> Int32 {
  var i: UInt64 = 0
  while i < na && i < nb {
    let x = a.byteAt(pa + i)
    let y = b.byteAt(pb + i)
    if x < y { return -1 }
    if x > y { return 1 }
    i += 1
  }
  if na < nb { return -1 }
  if na > nb { return 1 }
  return 0
}

// A malformed later member invalidates earlier matches. A valid miss is
// distinct from an invalid archive. Paths are compared as unsigned UTF-8.
public func findBootMember<S: ByteSource, N: ByteSource>(_ src: S, name: N) -> BootMember {
  let end = src.byteCount()
  if end < 24 || little(src, at: 0, bytes: 8) != 0x0000_0001_4152_4954
    || little(src, at: 12, bytes: 4) != 0
  {
    return emptyMember()
  }
  let count = little(src, at: 8, bytes: 4)
  let table = little(src, at: 16, bytes: 8)
  if table < 24 || table > end || count == 0 || count > (end - table) / 59 { return emptyMember() }
  var pos = table
  var prev: UInt64 = 0
  var prevBytes: UInt64 = 0
  var i: UInt64 = 0
  var member = emptyMember()
  while i < count {
    let bytes = pathLength(src, pos: &pos)
    if bytes == 0 || bytes > end - pos || !archivePath(src, start: pos, length: bytes) {
      return emptyMember()
    }
    if i != 0 && comparePaths(src, pa: prev, na: prevBytes, b: src, pb: pos, nb: bytes) >= 0 {
      return emptyMember()
    }
    prev = pos
    prevBytes = bytes
    pos += bytes
    if end - pos < 57 { return emptyMember() }
    let offset = little(src, at: pos, bytes: 8)
    let stored = little(src, at: pos + 8, bytes: 8)
    let size = little(src, at: pos + 16, bytes: 8)
    let codec = src.byteAt(pos + 24)
    if offset < 24 || offset > table || stored > table - offset || codec > 1
      || (codec == 0 && stored != size) || (codec == 1 && stored == 0)
    {
      return emptyMember()
    }
    if comparePaths(src, pa: prev, na: bytes, b: name, pb: 0, nb: name.byteCount()) == 0 {
      member = BootMember(
        validArchive: false, found: true, offset: offset, stored: stored, size: size,
        compression: codec, digestAt: pos + 25)
    }
    pos += 57
    i += 1
  }
  if pos != end { return emptyMember() }
  member.validArchive = true
  return member
}
