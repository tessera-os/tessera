/// Read-only canonicalisation for the unsigned linker artifact. The signature
/// envelope and its trust policy are not inputs to this operation.
private struct DigestView {
  let bytes: UnsafeRawBufferPointer
  let zeros: Range<Int>

  func word(_ at: Int, _ end: Int) -> UInt32 {
    let n = min(end - at, 4)
    if n == 4 && (at >= zeros.upperBound || at + 4 <= zeros.lowerBound) {
      return UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: at, as: UInt32.self))
    }
    guard n > 0 else { return 0 }
    var word: UInt32 = 0
    for i in 0..<n where !zeros.contains(at + i) {
      word |= UInt32(bytes[at + i]) << (8 * i)
    }
    return word
  }

  func cv(_ at: Int, _ end: Int) -> BlakeCv {
    BlakeCv(
      w0: word(at, end), w1: word(at + 4, end), w2: word(at + 8, end),
      w3: word(at + 12, end), w4: word(at + 16, end), w5: word(at + 20, end),
      w6: word(at + 24, end), w7: word(at + 28, end))
  }
}

// Trees are left-balanced: merge completed equal-sized subtrees, then
// fold the last leaf against the pending left siblings, smallest first.
func digestImage(
  _ bytes: UnsafeRawBufferPointer, zeros: Range<Int>,
  stack: UnsafeMutableBufferPointer<BlakeCv>
) -> BlakeCv? {
  guard zeros.lowerBound >= 0, zeros.upperBound <= bytes.count,
    bytes.count <= Int.max - 1024
  else { return nil }
  let size = UInt64(bytes.count)
  let last = bytes.isEmpty ? 0 : (bytes.count - 1) / 1024
  let levels = last == 0 ? 0 : Int.bitWidth - last.leadingZeroBitCount
  guard stack.count >= levels else { return nil }
  let view = DigestView(bytes: bytes, zeros: zeros)
  var used = 0
  var at = 0
  for index in 0...last {
    var leaf = imageChunk(size, UInt64(index))
    repeat {
      let n = Int(min(leaf.remaining, 64))
      let end = at + n
      let block = BlakeBlock(low: view.cv(at, end), high: view.cv(at + 32, end))
      guard leaf.absorb(block, UInt32(n)) else { return nil }
      at = end
    } while !leaf.hashed
    var cv = leaf.chain
    if index == last {
      while used > 0 {
        used -= 1
        let pair = BlakeBlock(low: stack[used], high: cv)
        cv = blakeCompress(initialCv(), pair, 0, 64, used == 0 ? 12 : 4)
      }
      return cv
    }
    var n = index + 1
    while n & 1 == 0 {
      used -= 1
      cv = imageParentCv(stack[used], cv)
      n >>= 1
    }
    stack[used] = cv
    used += 1
  }
  return nil
}

/// Hash the entire unsigned image with the 32-byte ID descriptor zeroed.
/// Scratch must be disjoint from the immutable snapshot; 54 CVs suffice
/// for every supported file length. This ID is not a launch credential.
public func unsignedBuildID(
  _ bytes: UnsafeRawBufferPointer, descriptor: Range<Int>,
  scratch: UnsafeMutableBufferPointer<BlakeCv>
) -> BlakeCv? {
  guard descriptor.lowerBound >= 0, descriptor.upperBound <= bytes.count,
    descriptor.count == 32
  else { return nil }
  return digestImage(bytes, zeros: descriptor, stack: scratch)
}
