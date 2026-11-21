func littleWord(_ bytes: UnsafeBufferPointer<UInt8>, _ start: UInt64, _ end: UInt64) -> UInt32 {
  var value: UInt32 = 0
  for byte in 0..<4 {
    let at = start + UInt64(byte)
    if at < end { value = value | (UInt32(bytes[Int(at)]) << UInt32(byte * 8)) }
  }
  return value
}

func littleCv(_ bytes: UnsafeBufferPointer<UInt8>, _ at: UInt64, _ end: UInt64) -> BlakeCv {
  return BlakeCv(
    w0: littleWord(bytes, at + 0, end),
    w1: littleWord(bytes, at + 4, end),
    w2: littleWord(bytes, at + 8, end),
    w3: littleWord(bytes, at + 12, end),
    w4: littleWord(bytes, at + 16, end),
    w5: littleWord(bytes, at + 20, end),
    w6: littleWord(bytes, at + 24, end),
    w7: littleWord(bytes, at + 28, end))
}

// Views are stable for the entire borrow. Frame is exactly one private,
// read-only pinned page, not a userspace buffer. Witness bytes are a
// kernel-private cache layout: 32-byte sibling CVs leaf-to-root for each
// successive 1 KiB chunk; direction, length and ROOT are never trusted.
public func verifyFilePage(
  _ frame: UnsafeBufferPointer<UInt8>,
  _ witnesses: UnsafeBufferPointer<UInt8>,
  _ size: UInt64,
  _ fileOffset: UInt64,
  _ pageSize: UInt64,
  _ signedRoot: BlakeCv
) -> Bool {
  if UInt64(frame.count) != pageSize { return false }
  var page = pageIntegrity(size, fileOffset, pageSize, signedRoot)
  if page.failed { return false }
  var valid = size - fileOffset
  if valid > pageSize { valid = pageSize }
  let witnessBytes = UInt64(witnesses.count)
  // UInt64 image size gives at most 2^54 chunks and at most 54 siblings.
  if witnessBytes % 32 != 0 || witnessBytes > UInt64(16 * 54 * 32) { return false }
  var p: UInt64 = 0
  var w: UInt64 = 0
  while p < valid {
    var leaf = imageChunk(size, page.nextChunk)
    while !leaf.hashed {
      var length = leaf.remaining
      if length > 64 { length = 64 }
      if length == 0 || length > valid - p { return false }
      let end = p + length
      let block = BlakeBlock(
        low: littleCv(frame, p, end),
        high: littleCv(frame, p + 32, end))
      if !leaf.absorb(block, UInt32(length)) { return false }
      p = end
    }
    while leaf.nodes > 1 {
      if witnessBytes - w < 32 { return false }
      if !leaf.sibling(littleCv(witnesses, w, w + 32)) { return false }
      w += 32
    }
    if !page.accept(leaf) { return false }
  }
  while p < pageSize {
    if frame[Int(p)] != 0 { return false }
    p += 1
  }
  return w == witnessBytes && page.verified()
}
