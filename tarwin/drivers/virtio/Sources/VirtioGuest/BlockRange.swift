public struct BlockRangeLimits: Equatable {
  public let capacity: UInt64
  public let sectors: UInt32
  public let segments: UInt32
  public let alignment: UInt32
  public let mayUnmap: Bool

  public init(
    capacity: UInt64, sectors: UInt32, segments: UInt32, alignment: UInt32, mayUnmap: Bool
  ) {
    self.capacity = capacity
    self.sectors = sectors
    self.segments = segments
    self.alignment = alignment
    self.mayUnmap = mayUnmap
  }
  public func supports(
    _ op: GuestBlockOp, sector: UInt64, sectors: UInt32, unmap: Bool, features: UInt64
  ) -> Bool {
    let zeroes = op == .writeZeroes
    if !zeroes && op != .discard { return false }
    let required: UInt64 = zeroes ? 0x4000 : 0x2000
    if (features & 32) != 0 || (features & required) == 0 || segments == 0
      || sectors == 0 || sectors > self.sectors || sector >= capacity
      || UInt64(sectors) > capacity - sector || (unmap && (!zeroes || !mayUnmap))
      || (!zeroes && alignment > 1 && sector % UInt64(alignment) != 0)
    {
      return false
    }
    return true
  }
}

// A single checked range; the caller owns the three exclusive DMA buffers
// through completion. Split larger requests to obey the device config.
public func submitRange(
  _ queue: inout SplitQueue, _ cookie: UInt64, _ p: BlockPacket, _ sectors: UInt32, _ unmap: Bool,
  _ limits: BlockRangeLimits, _ features: UInt64, _ storeHeader: (UInt64, UInt32, UInt64) -> Void,
  _ storeRange: (UInt64, UInt64, UInt32, UInt32) -> Void, _ setStatus: (UInt64, UInt8) -> Void,
  _ descriptor: (Int, UInt64, UInt32, UInt16, UInt16) -> Void,
  _ putAvailable: (Int, UInt16) -> Void, _ releaseAvailable: (UInt16) -> Void
) -> Bool {
  let zeroes = p.op == .writeZeroes
  guard p.bytes == 16,
    limits.supports(p.op, sector: p.sector, sectors: sectors, unmap: unmap, features: features)
  else { return false }
  if !validArea(p.header, 16, 1) || !validArea(p.data, 16, 1)
    || !distinctAreas(p.header, 16, p.data, 16) || !distinctAreas(p.header, 16, p.status, 1)
    || !distinctAreas(p.data, 16, p.status, 1)
  {
    return false
  }
  let parts = [
    Segment(iova: p.header, length: 16, deviceWrites: false),
    Segment(iova: p.data, length: 16, deviceWrites: false),
    Segment(iova: p.status, length: 1, deviceWrites: true),
  ]
  storeHeader(p.header, zeroes ? 13 : 11, 0)
  storeRange(p.data, p.sector, sectors, unmap ? 1 : 0)
  setStatus(p.status, 255)
  return queue.submit(cookie, parts, descriptor, putAvailable, releaseAvailable)
}
