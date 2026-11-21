import TarwinBlockWire
import TarwinIPC
import VirtioGuest

public enum DriverRequest {
  case invalid
  case unsupported(BlockCompletion)
  case ready(PendingBlockIo)
}
public struct PendingBlockIo {
  fileprivate let packet: BlockPacket
  public let id: UInt64, epoch: UInt64, queue: UInt32
  public var op: GuestBlockOp { packet.op }
  fileprivate let config: BlockConfiguration
  fileprivate let spans: [Segment]
  fileprivate let range: BlockRangeLimits?, sectors: UInt32
  public func submit(
    _ queue: inout SplitQueue,
    storeHeader: (UInt64, UInt32, UInt64) -> Void,
    storeRange: (UInt64, UInt64, UInt32, UInt32) -> Void,
    setStatus: (UInt64, UInt8) -> Void, descriptor: (Int, UInt64, UInt32, UInt16, UInt16) -> Void,
    putAvailable: (Int, UInt16) -> Void, releaseAvailable: (UInt16) -> Void
  ) -> Bool {
    if let range {
      return submitRange(
        &queue, id, packet, sectors, false, range, config.features, storeHeader, storeRange,
        setStatus, descriptor, putAvailable, releaseAvailable)
    }
    return submitBlock(
      &queue, id, packet, config, spans, storeHeader, setStatus, descriptor,
      putAvailable, releaseAvailable)
  }
  public func complete(cookie: UInt64, status: UInt8, written: UInt32) -> BlockCompletion? {
    guard cookie == id else { return nil }
    let result: BlockStatus
    switch blockCompletion(status, packet.op, packet.bytes, written) {
    case .ok: result = .ok
    case .mediaError: result = .media
    case .unsupported: result = .unsupported
    case .protocolError: return nil
    }
    return BlockCompletion(id: id, epoch: epoch, queue: queue, status: result)
  }
}

/// Without a configuration snapshot the service accepts one data vector.
/// The vector table (u64 IOVA, u32 bytes, u32 zero) is read only through a
/// validated live grant; it is never treated as a physical or Swift pointer.
public func prepareBlockIo(
  _ record: borrowing RingRecord, epoch: UInt64, queue: UInt32,
  capacitySectors: UInt64, features: UInt64, header: UInt64, status: UInt64,
  allows: (UInt64, UInt64, Bool) -> Bool,
  readVector: (UInt64) -> BlockDmaVector?
) -> DriverRequest {
  prepareBlockIo(
    record, epoch: epoch, queue: queue,
    config: BlockConfiguration(capacity: capacitySectors, features: features), header: header,
    status: status, rangeBuffer: nil, allows: allows, readVector: readVector)
}

/// rangeBuffer is a driver-owned, exclusive 16-byte device-readable scratch
/// range, never a client vector. Hold it through used-ring completion.
public func prepareBlockIo(
  _ record: borrowing RingRecord, epoch: UInt64, queue: UInt32, config: BlockConfiguration,
  header: UInt64, status: UInt64, rangeBuffer: UInt64?,
  allows: (UInt64, UInt64, Bool) -> Bool, readVector: (UInt64) -> BlockDmaVector?
) -> DriverRequest {
  let features = config.features
  let capacitySectors = config.capacity
  guard let r = BlockRequest(record: record, epoch: epoch, queue: queue) else { return .invalid }
  let unsupported = BlockCompletion(id: r.id, epoch: epoch, queue: queue, status: .unsupported)
  let op: GuestBlockOp
  switch r.op {
  case .read: op = .read
  case .write: op = .write
  case .flush: op = .flush
  case .discard, .zero:
    let discard = r.op == .discard
    op = discard ? .discard : .writeZeroes
    guard let limit = discard ? config.discard : config.zero,
      let sectors = UInt32(exactly: r.blocks),
      limit.supports(op, sector: r.lba, sectors: sectors, unmap: false, features: features)
    else { return .unsupported(unsupported) }
    guard let scratch = rangeBuffer else { return .invalid }
    return .ready(
      PendingBlockIo(
        packet: BlockPacket(
          op: op, sector: r.lba, bytes: 16, header: header, data: scratch, status: status),
        id: r.id, epoch: r.epoch, queue: queue, config: config, spans: [], range: limit,
        sectors: sectors))
  default: return .unsupported(unsupported)
  }
  guard
    let limits = BlockLimits(
      capacity: capacitySectors, blockBytes: 512, maxVectors: config.maxSegments,
      flush: features & 512 != 0, fua: false, discard: false, zero: false,
      readOnly: features & 32 != 0)
  else { return .invalid }
  if (op == .flush && !limits.flush) || (op == .write && limits.readOnly) {
    return .unsupported(unsupported)
  }
  guard limits.supports(r) else { return .invalid }
  var vectors: [BlockDmaVector] = []
  if op != .flush {
    let bytes = UInt64(r.payload.vectors) * 16
    guard r.blocks <= UInt64(UInt32.max - 17) / 512,
      distinctAreas(r.payload.list, bytes, header, 16),
      distinctAreas(r.payload.list, bytes, status, 1),
      allows(r.payload.list, bytes, false)
    else { return .invalid }
    for i in 0..<r.payload.vectors {
      guard let v = readVector(r.payload.list + UInt64(i) * 16), v.bytes <= config.maxSegmentBytes,
        distinctAreas(v.address, UInt64(v.bytes), header, 16),
        distinctAreas(v.address, UInt64(v.bytes), status, 1),
        vectors.allSatisfy({
          distinctAreas(v.address, UInt64(v.bytes), $0.address, UInt64($0.bytes))
        })
      else { return .invalid }
      vectors.append(v)
    }
    guard
      vectors.withUnsafeBufferPointer({ limits.checkVectors(r, snapshot: $0, validate: allows) })
    else { return .invalid }
  }
  let spans = vectors.map { Segment(iova: $0.address, length: $0.bytes, deviceWrites: op == .read) }
  return .ready(
    PendingBlockIo(
      packet: BlockPacket(
        op: op, sector: r.lba, bytes: UInt32(r.blocks * 512),
        header: header, data: vectors.first?.address ?? 0, status: status), id: r.id, epoch: epoch,
      queue: queue,
      config: config, spans: spans, range: nil, sectors: 0)
  )
}
