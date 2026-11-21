import KCore

// Roll against all aligned starts, not all descriptors: a four-page extent
// contributes four placements for one page, but only one for four pages.
struct CandidateSpan {
  let base: UInt64
  let count: UInt64

  init?(_ r: FirmwareRegion, bytes: UInt64, alignment: UInt64) {
    // Ordinary write-back conventional memory; exclude read/write-protected,
    // persistent, special-purpose, ISA-specific and firmware runtime memory.
    guard r.type == 7, r.attributes & 8 != 0, r.attributes & 0xc000_0000_0006_a000 == 0,
      bytes > 0, isPowerOfTwo(alignment), validExtent(r.base, length: r.length)
    else { return nil }
    let skip = r.base == 0 ? alignment : (0 &- r.base) & (alignment - 1)
    guard skip <= r.length, bytes <= r.length - skip else { return nil }
    base = r.base + skip
    count = 1 + (r.length - skip - bytes) / alignment
  }
}

func unbiasedRank(_ word: UInt64, count: UInt64) -> UInt64? {
  guard count > 0, word >= (0 &- count) % count else { return nil }
  return word % count
}

/// The caller supplies a reserved upper-half virtual region for the chosen MMU
/// geometry, excluding the direct map, heap, per-CPU data and stack regions.
func virtualBase(region: Range<UInt64>, bytes: UInt64, alignment: UInt64, word: UInt64) -> UInt64? {
  let slots: UInt64 = 1 << 18
  guard region.lowerBound >= 1 << 63, alignedTo(region.lowerBound, alignment: alignment),
    alignment >= 4096, bytes > 0, bytes <= region.upperBound - region.lowerBound,
    (region.upperBound - region.lowerBound - bytes) / alignment >= slots - 1
  else { return nil }
  return region.lowerBound + (word & (slots - 1)) * alignment
}

// Only called on the validated, sorted, immutable prefix from stageFirmwareMap.
func physicalBase(_ regions: UnsafeBufferPointer<FirmwareRegion>, bytes: UInt64, alignment: UInt64,
  word: UInt64) -> UInt64? {
  var count: UInt64 = 0
  for region in regions {
    if let span = CandidateSpan(region, bytes: bytes, alignment: alignment) {
      guard count <= UInt64.max - span.count else { return nil }
      count += span.count
    }
  }
  guard var rank = unbiasedRank(word, count: count) else { return nil }
  for region in regions {
    if let span = CandidateSpan(region, bytes: bytes, alignment: alignment) {
      if rank < span.count { return span.base + rank * alignment }
      rank -= span.count
    }
  }
  return nil
}
