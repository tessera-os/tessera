import KCore

// Raw LZ4 blocks, without an embedded size. The pager supplies private,
// non-overlapping buffers and the authenticated logical size (page + tags).
// Scratch is a per-operation 4096-entry dictionary; no allocation or sleep.
// On failure output is unpublished and must be discarded.
public protocol MatchTable {
  mutating func clear()
  func previous(_ bucket: UInt16) -> UInt16
  mutating func record(_ bucket: UInt16, positionPlusOne: UInt16)
}

/// Reusable per-worker scratch, exclusively held for an entire compression.
public struct PageMatchTable: MatchTable {
  private let entries: UnsafeMutableBufferPointer<UInt16>
  public init?(_ entries: UnsafeMutableBufferPointer<UInt16>) {
    guard entries.count == 4096 else { return nil }
    self.entries = entries
  }
  public mutating func clear() { for i in entries.indices { entries[i] = 0 } }
  public func previous(_ bucket: UInt16) -> UInt16 { entries[Int(bucket)] }
  public mutating func record(_ bucket: UInt16, positionPlusOne: UInt16) {
    entries[Int(bucket)] = positionPlusOne
  }
}

public struct BlockSize {
  public internal(set) var ok: Bool
  public internal(set) var count: UInt64
}

func noBlock() -> BlockSize { return BlockSize(ok: false, count: 0) }

func wordAt<S: ByteSource>(_ input: S, p: UInt64) -> UInt64 {
  return UInt64(input.byteAt(p)) | (UInt64(input.byteAt(p + 1)) << 8)
    | (UInt64(input.byteAt(p + 2)) << 16) | (UInt64(input.byteAt(p + 3)) << 24)
}

func emitLength<D: ByteBuffer>(_ output: inout D, cursor: inout UInt64, n: UInt64) {
  var extra = n - 15
  while extra >= 255 {
    output.putByte(cursor, value: 255)
    cursor += 1
    extra -= 255
  }
  output.putByte(cursor, value: UInt8(extra))
  cursor += 1
}

func extBytes(_ n: UInt64) -> UInt64 {
  if n < 15 { return 0 }
  return (n - 15) / 255 + 1
}

func sequence<S: ByteSource, D: ByteBuffer>(
  _ input: S, output: inout D, cursor: inout UInt64, literalAt: UInt64, literals: UInt64,
  distance: UInt64, matched: UInt64
) -> Bool {
  let code = distance == 0 ? UInt64(0) : matched - 4
  var need = 1 + extBytes(literals) + literals
  if distance != 0 { need += 2 + extBytes(code) }
  if need > output.byteCount() - cursor { return false }
  let hi = literals < 15 ? literals : UInt64(15)
  let lo = code < 15 ? code : UInt64(15)
  output.putByte(cursor, value: UInt8(hi * 16 + lo))
  cursor += 1
  if literals >= 15 { emitLength(&output, cursor: &cursor, n: literals) }
  var i: UInt64 = 0
  while i < literals {
    output.putByte(cursor, value: input.byteAt(literalAt + i))
    cursor += 1
    i += 1
  }
  if distance != 0 {
    output.putByte(cursor, value: UInt8(distance & 255))
    output.putByte(cursor + 1, value: UInt8(distance >> 8))
    cursor += 2
    if code >= 15 { emitLength(&output, cursor: &cursor, n: code) }
  }
  return true
}

public func compressPage<S: ByteSource, D: ByteBuffer, H: MatchTable>(
  _ input: S, output: inout D, table: inout H
) -> BlockSize {
  let size = input.byteCount()
  if size == 0 || size > 32768 { return noBlock() }
  table.clear()
  var anchor: UInt64 = 0
  var p: UInt64 = 0
  var written: UInt64 = 0
  while size - p >= 12 {
    let word = wordAt(input, p: p)
    let bucket = UInt16(((word * 2_654_435_761) >> 20) & 4095)
    let saved = UInt64(table.previous(bucket))
    table.record(bucket, positionPlusOne: UInt16(p + 1))
    if saved == 0 || saved > p || wordAt(input, p: saved - 1) != word {
      p += 1
    } else {
      let source = saved - 1
      var matched: UInt64 = 4
      while matched < size - p - 5 && input.byteAt(source + matched) == input.byteAt(p + matched) {
        matched += 1
      }
      if !sequence(
        input, output: &output, cursor: &written, literalAt: anchor, literals: p - anchor,
        distance: p - source, matched: matched)
      {
        return noBlock()
      }
      p += matched
      anchor = p
    }
  }
  if !sequence(
    input, output: &output, cursor: &written, literalAt: anchor, literals: size - anchor,
    distance: 0, matched: 0)
  {
    return noBlock()
  }
  return BlockSize(ok: true, count: written)
}

func parseLength<S: ByteSource>(_ input: S, end: UInt64, pos: inout UInt64, nibble: UInt64)
  -> BlockSize
{
  var n = nibble
  if n == 15 {
    while true {
      if pos == end { return noBlock() }
      let extra = UInt64(input.byteAt(pos))
      pos += 1
      n += extra
      if n > 32768 { return noBlock() }
      if extra != 255 { break }
    }
  }
  return BlockSize(ok: true, count: n)
}

public func decompressPage<S: ByteSource, D: ByteBuffer>(
  _ input: S, stored: UInt64, output: inout D, logical: UInt64
) -> Bool {
  if logical == 0 || logical > 32768 || logical > output.byteCount() || stored == 0
    || stored > input.byteCount() || stored > logical + logical / 255 + 16
  {
    return false
  }
  var pos: UInt64 = 0
  var written: UInt64 = 0
  while pos < stored {
    let token = input.byteAt(pos)
    pos += 1
    let literal = parseLength(input, end: stored, pos: &pos, nibble: UInt64(token >> 4))
    if !literal.ok || literal.count > stored - pos || literal.count > logical - written {
      return false
    }
    var i: UInt64 = 0
    while i < literal.count {
      output.putByte(written, value: input.byteAt(pos))
      pos += 1
      written += 1
      i += 1
    }
    if pos == stored { return written == logical }
    if stored - pos < 2 { return false }
    let distance = UInt64(input.byteAt(pos)) | (UInt64(input.byteAt(pos + 1)) << 8)
    pos += 2
    if distance == 0 || distance > written { return false }
    let length = parseLength(input, end: stored, pos: &pos, nibble: UInt64(token & 15))
    if !length.ok || length.count + 4 > logical - written { return false }
    i = 0
    while i < length.count + 4 {
      let byte = output.byteAt(written - distance)
      output.putByte(written, value: byte)
      written += 1
      i += 1
    }
  }
  return false
}
