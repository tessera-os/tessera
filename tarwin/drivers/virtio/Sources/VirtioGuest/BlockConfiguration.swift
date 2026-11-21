/// Virtio 1.3 §5.2.4. All sizes and LBAs in this interface use 512-byte
/// sectors. Call again after a configuration-change notification, while
/// registration and new submissions are stopped.
public struct BlockConfiguration {
  public let capacity: UInt64, features: UInt64, discard: BlockRangeLimits?, zero: BlockRangeLimits?
  public let maxSegments: UInt32, maxSegmentBytes: UInt32
  public init(capacity: UInt64, features: UInt64) {
    self.capacity = capacity
    self.features = features
    // Without a stable config snapshot no negotiated limit may be guessed.
    maxSegments = features & 4 == 0 ? 1 : 0
    maxSegmentBytes = features & 2 == 0 ? .max : 0
    discard = nil
    zero = nil
  }
  private init(
    capacity: UInt64, features: UInt64, discard: BlockRangeLimits?, zero: BlockRangeLimits?,
    maxSegments: UInt32, maxSegmentBytes: UInt32
  ) {
    self.capacity = capacity
    self.features = features
    self.discard = discard
    self.zero = zero
    self.maxSegments = maxSegments
    self.maxSegmentBytes = maxSegmentBytes
  }
  public static func snapshot(
    features: UInt64, configBytes: UInt64, generation: () -> UInt32, read: (Int) -> UInt8
  ) -> Self? {
    let d = features & 0x2000 != 0
    let z = features & 0x4000 != 0
    guard configBytes >= (z ? 57 : d ? 48 : features & 4 != 0 ? 16 : features & 2 != 0 ? 12 : 8)
    else { return nil }
    func le(_ offset: Int, _ n: Int) -> UInt64 {
      (0..<n).reduce(0) { $0 | UInt64(read(offset + $1)) << (8 * $1) }
    }
    for _ in 0..<8 {
      let before = generation()
      let capacity = le(0, 8)
      let bytes: UInt32 = features & 2 != 0 ? UInt32(le(8, 4)) : .max
      let segments: UInt32 = features & 4 != 0 ? min(128, UInt32(le(12, 4))) : 1
      func limits(_ base: Int, _ discard: Bool) -> BlockRangeLimits {
        BlockRangeLimits(
          capacity: capacity, sectors: UInt32(le(base, 4)), segments: UInt32(le(base + 4, 4)),
          alignment: discard ? UInt32(le(base + 8, 4)) : 0,
          mayUnmap: !discard && read(base + 8) == 1)
      }
      let dl = d ? limits(36, true) : nil
      let zl = z ? limits(48, false) : nil
      guard generation() == before else { continue }
      guard capacity > 0, bytes > 0, segments > 0 else { return nil }
      return Self(
        capacity: capacity, features: features, discard: dl, zero: zl,
        maxSegments: segments, maxSegmentBytes: bytes)
    }
    return nil
  }
}
