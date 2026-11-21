// Decode one RELR table. An even word selects an explicit 8-byte slot;
// an odd word selects a bitmap of the next 63 slots. Each accepted word
// exposes pending offsets one at a time, in order, without allocating.
// Callers still check every slot is in a relocatable non-code segment.
public struct RelativeCursor {
  public internal(set) var anchorSeen: Bool
  public internal(set) var nextBase: UInt64
  public internal(set) var bits: UInt64
  public internal(set) var at: UInt64
  public let imageSize: UInt64

  public mutating func accept(_ word: UInt64) -> Bool {
    if bits != 0 { return false }
    if (word & 1) == 0 {
      if (word & 7) != 0 || !imageContains(imageSize, word, 8) { return false }
      if anchorSeen && word < nextBase { return false }
      at = word
      bits = 1
      nextBase = word + 8
      anchorSeen = true
      return true
    }
    if !anchorSeen || nextBase > 0xffff_ffff_ffff_fe07 { return false }
    let selected = word >> 1
    // A final sparse bitmap may extend beyond the image in unset bits.
    if selected != 0 {
      var high = selected
      var extent: UInt64 = 8
      while high > 1 {
        high = high >> 1
        extent += 8
      }
      if !imageContains(imageSize, nextBase, extent) { return false }
    }
    at = nextBase
    bits = selected
    nextBase += 504
    return true
  }

  // Valid only while bits != 0. The sentinel cannot be an aligned slot.
  public mutating func take() -> UInt64 {
    if bits == 0 { return 0xffff_ffff_ffff_ffff }
    while (bits & 1) == 0 {
      bits = bits >> 1
      at += 8
    }
    let slot = at
    at += 8
    bits = bits >> 1
    return slot
  }

  public init(anchorSeen: Bool, nextBase: UInt64, bits: UInt64, at: UInt64, imageSize: UInt64) {
    self.anchorSeen = anchorSeen
    self.nextBase = nextBase
    self.bits = bits
    self.at = at
    self.imageSize = imageSize
  }
}
