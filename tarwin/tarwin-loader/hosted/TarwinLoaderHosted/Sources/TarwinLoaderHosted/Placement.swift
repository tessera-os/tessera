import TarwinMMHosted

public let hostedImageWindowSize: UInt64 = 64 << 30

public enum HostedImageError: Error, Equatable {
  case invalidImage
  case noPlacement
  case invalidRelocations
  case invalidTrapRewrite
  case rollbackFailed
}

public enum HostedImagePlacement {
  public static func choose<R: RandomNumberGenerator>(
    window: Range<UInt64>, occupied: [Range<UInt64>], span: UInt64, alignment: UInt64,
    using random: inout R
  ) throws -> UInt64 {
    guard window.upperBound - window.lowerBound == hostedImageWindowSize,
      window.lowerBound % hostedPageSize == 0,
      span > 0, span <= hostedImageWindowSize, span % hostedPageSize == 0,
      alignment >= hostedPageSize, alignment <= hostedImageWindowSize,
      alignment.nonzeroBitCount == 1
    else { throw HostedImageError.noPlacement }

    var gaps: [(base: UInt64, count: UInt64)] = []
    func scan(_ start: UInt64, _ end: UInt64) {
      let pad = (0 &- start) & (alignment - 1)
      guard start <= end, pad <= end - start, span <= end - start - pad else { return }
      let base = start + pad
      gaps.append((base, (end - base - span) / alignment + 1))
    }
    var cursor = window.lowerBound
    for used in occupied.sorted(by: { $0.lowerBound < $1.lowerBound }) where used.overlaps(window) {
      scan(cursor, used.lowerBound)
      cursor = max(cursor, min(used.upperBound, window.upperBound))
    }
    scan(cursor, window.upperBound)
    let count = gaps.reduce(0) { $0 + $1.count }
    guard count > 0 else { throw HostedImageError.noPlacement }
    var rank = UInt64.random(in: 0..<count, using: &random)
    for gap in gaps {
      if rank < gap.count { return gap.base + rank * alignment }
      rank -= gap.count
    }
    throw HostedImageError.noPlacement
  }
}
