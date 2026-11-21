/// Appendix A.2: the same half-open image window on all three ISAs.
public let imageWindow: Range<UInt64> = (1 << 32)..<(1 << 43)
public let minimumImagePositions: UInt64 = 1 << 28

/// Borrows the complete, sorted image reservations under the process map
/// lock. Do not mutate the snapshot between counting, selecting and commit.
public struct ImagePlacementSpace {
  private let occupied: UnsafeBufferPointer<Range<UInt64>>
  private let extra: Range<UInt64>?
  private let span, alignment: UInt64
  public private(set) var positions: UInt64

  public init?(
    machine: UInt16, span: UInt64, alignment: UInt64,
    occupied: UnsafeBufferPointer<Range<UInt64>>, excluding extra: Range<UInt64>? = nil
  ) {
    let page = imagePage(machine)
    guard page != 0, alignment >= page, alignment.nonzeroBitCount == 1,
      span > 0, span % page == 0
    else { return nil }
    func valid(_ r: Range<UInt64>) -> Bool {
      !r.isEmpty && r.lowerBound >= imageWindow.lowerBound && r.upperBound <= imageWindow.upperBound
        && r.lowerBound % page == 0 && r.upperBound % page == 0
    }
    if let extra, !valid(extra) { return nil }
    var end = imageWindow.lowerBound
    for r in occupied {
      guard valid(r), r.lowerBound >= end, extra?.overlaps(r) != true else { return nil }
      end = r.upperBound
    }
    self.occupied = occupied
    self.extra = extra
    self.span = span
    self.alignment = alignment
    positions = 0
    var count: UInt64 = 0
    _ = visit { _, n in
      count += n
      return true
    }
    positions = count
  }

  /// Returns nil only for insufficient positions or a rejected random word.
  /// In the latter case use a fresh CSPRNG draw, never increment the word.
  public func reservation(randomWord: UInt64) -> Range<UInt64>? {
    guard positions >= minimumImagePositions, randomWord >= (0 &- positions) % positions
    else { return nil }
    var rank = randomWord % positions
    var result: Range<UInt64>?
    _ = visit { first, n in
      if rank >= n {
        rank -= n
        return true
      }
      let base = first + rank * alignment
      result = base..<base + span
      return false
    }
    return result
  }

  private func visit(_ run: (UInt64, UInt64) -> Bool) -> Bool {
    func gap(_ lo: UInt64, _ hi: UInt64) -> Bool {
      // lo <= 2^43 and a valid power-of-two alignment is at most 2^63.
      let first = (lo + (alignment - 1)) & ~(alignment - 1)
      guard first <= hi, span <= hi - first else { return true }
      return run(first, (hi - first - span) / alignment + 1)
    }
    var at = imageWindow.lowerBound
    var insert = extra
    for r in occupied {
      if let e = insert, e.upperBound <= r.lowerBound {
        guard gap(at, e.lowerBound) else { return false }
        at = e.upperBound
        insert = nil
      }
      guard gap(at, r.lowerBound) else { return false }
      at = r.upperBound
    }
    if let e = insert {
      guard gap(at, e.lowerBound) else { return false }
      at = e.upperBound
    }
    return gap(at, imageWindow.upperBound)
  }
}
