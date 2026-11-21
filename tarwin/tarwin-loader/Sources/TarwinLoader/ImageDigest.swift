/// Logical file offsets omit the raw signature bytes. Substitution of the
/// ID uses physical offsets, including when the ID follows the signatures.
private struct DigestView {
  let bytes: UnsafeRawBufferPointer
  let zeros: Range<Int>
  let omit: Range<Int>

  func word(_ at: Int, _ end: Int) -> UInt32 {
    let n = min(end - at, 4)
    guard n > 0 else { return 0 }
    let off = at < omit.lowerBound ? at : at + omit.count
    if n == 4 && (at >= omit.lowerBound || at + 4 <= omit.lowerBound)
      && (off >= zeros.upperBound || off + 4 <= zeros.lowerBound)
    {
      return UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: off, as: UInt32.self))
    }
    var word: UInt32 = 0
    for i in 0..<n {
      let p = at + i < omit.lowerBound ? at + i : at + i + omit.count
      if !zeros.contains(p) { word |= UInt32(bytes[p]) << (8 * i) }
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
  _ bytes: UnsafeRawBufferPointer, zeros: Range<Int>, omit: Range<Int> = 0..<0,
  stack: UnsafeMutableBufferPointer<BlakeCv>
) -> BlakeCv? {
  guard zeros.lowerBound >= 0, zeros.upperBound <= bytes.count,
    omit.lowerBound >= 0, omit.upperBound <= bytes.count, !omit.overlaps(zeros),
    bytes.count <= Int.max - 1024
  else { return nil }
  let size = UInt64(bytes.count - omit.count)
  let last = size == 0 ? 0 : (Int(size) - 1) / 1024
  let levels = last == 0 ? 0 : Int.bitWidth - last.leadingZeroBitCount
  guard stack.count >= levels else { return nil }
  let view = DigestView(bytes: bytes, zeros: zeros, omit: omit)
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
