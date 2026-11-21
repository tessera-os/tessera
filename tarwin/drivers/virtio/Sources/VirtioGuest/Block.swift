public enum GuestBlockOp: Equatable {
  case read
  case write
  case flush
  case discard
  case writeZeroes
}
public enum GuestBlockResult: Equatable {
  case ok
  case mediaError
  case unsupported
  case protocolError
}
public struct BlockPacket: Equatable {
  public let op: GuestBlockOp
  public let sector: UInt64
  public let bytes: UInt32
  public let header: UInt64
  public let data: UInt64
  public let status: UInt64

  public init(
    op: GuestBlockOp, sector: UInt64, bytes: UInt32, header: UInt64, data: UInt64, status: UInt64
  ) {
    self.op = op
    self.sector = sector
    self.bytes = bytes
    self.header = header
    self.data = data
    self.status = status
  }
}

public func submitBlock(
  _ queue: inout SplitQueue, _ cookie: UInt64, _ p: BlockPacket, _ capacitySectors: UInt64,
  _ features: UInt64, _ storeHeader: (UInt64, UInt32, UInt64) -> Void,
  _ setStatus: (UInt64, UInt8) -> Void, _ descriptor: (Int, UInt64, UInt32, UInt16, UInt16) -> Void,
  _ putAvailable: (Int, UInt16) -> Void, _ releaseAvailable: (UInt16) -> Void
) -> Bool {
  let spans =
    p.bytes == 0 ? [] : [Segment(iova: p.data, length: p.bytes, deviceWrites: p.op == .read)]
  return submitBlock(
    &queue, cookie, p, BlockConfiguration(capacity: capacitySectors, features: features),
    spans, storeHeader, setStatus, descriptor, putAvailable, releaseAvailable)
}

package func submitBlock(
  _ queue: inout SplitQueue, _ cookie: UInt64, _ p: BlockPacket, _ config: BlockConfiguration,
  _ spans: [Segment], _ storeHeader: (UInt64, UInt32, UInt64) -> Void,
  _ setStatus: (UInt64, UInt8) -> Void, _ descriptor: (Int, UInt64, UInt32, UInt16, UInt16) -> Void,
  _ putAvailable: (Int, UInt16) -> Void, _ releaseAvailable: (UInt16) -> Void
) -> Bool {
  let features = config.features
  let capacitySectors = config.capacity
  // The caller reserves independent, exclusive header, data and status
  // DMA spans lasting through completion. storeHeader writes the reserved
  // word as zero and type/sector little-endian.
  let write = p.op != .read && p.op != .flush
  if write && (features & 32) != 0 { return false }
  var kind: UInt32 = 0
  if p.op == .read || p.op == .write {
    if p.bytes == 0 || p.bytes % 512 != 0 || p.sector >= capacitySectors
      || UInt64(p.bytes / 512) > capacitySectors - p.sector
    {
      return false
    }
    if write { kind = 1 }
  } else if p.op == .flush {
    if (features & 512) == 0 || p.bytes != 0 || p.sector != 0 { return false }
    kind = 4
  } else {
    // Range-list requests require validated, device-limited range
    // records. Do not dispatch arbitrary buffers as discard ranges.
    return false
  }
  if !validArea(p.header, 16, 1) || !distinctAreas(p.header, 16, p.status, 1) { return false }
  var segments = [Segment(iova: p.header, length: 16, deviceWrites: false)]
  guard spans.count <= config.maxSegments, spans.count + 2 <= queue.size else { return false }
  var total: UInt64 = 0
  for span in spans {
    let length = UInt64(span.length)
    guard span.length <= config.maxSegmentBytes, validArea(span.iova, length, 1),
      span.deviceWrites == (p.op == .read), distinctAreas(span.iova, length, p.status, 1),
      segments.allSatisfy({ distinctAreas(span.iova, length, $0.iova, UInt64($0.length)) })
    else { return false }
    total += length
    segments.append(span)
  }
  guard total == UInt64(p.bytes), total <= UInt64(UInt32.max) - 17 else { return false }
  segments.append(Segment(iova: p.status, length: 1, deviceWrites: true))
  storeHeader(p.header, kind, p.sector)
  setStatus(p.status, 255)
  return queue.submit(cookie, segments, descriptor, putAvailable, releaseAvailable)
}

public func blockCompletion(
  _ status: UInt8, _ op: GuestBlockOp, _ dataBytes: UInt32, _ written: UInt32
) -> GuestBlockResult {
  if written == 0 { return .protocolError }
  if status == 0 && (op == .read ? written - 1 != dataBytes : written != 1) {
    return .protocolError
  }
  return switch status {
  case 0: .ok
  case 1: .mediaError
  case 2: .unsupported
  default: .protocolError
  }
}
