import TarwinBlockWire
import TarwinIPC
import VirtioGuest

public enum DriverRequest {
  case invalid
  case unsupported(BlockCompletion)
  case ready(PendingBlockIo)
}
public struct PendingBlockIo {
  public let packet: BlockPacket, id: UInt64, epoch: UInt64, queue: UInt32
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

/// Baseline service registers one contiguous DMA vector per read/write.
/// The vector table (u64 IOVA, u32 bytes, u32 zero) is read only through a
/// validated live grant; it is never treated as a physical or Swift pointer.
public func prepareBlockIo(
  _ record: borrowing RingRecord, epoch: UInt64, queue: UInt32,
  capacitySectors: UInt64, features: UInt64, header: UInt64, status: UInt64,
  allows: (UInt64, UInt64, Bool) -> Bool,
  readVector: (UInt64) -> BlockDmaVector?
) -> DriverRequest {
  guard let r = BlockRequest(record: record, epoch: epoch, queue: queue) else { return .invalid }
  let unsupported = BlockCompletion(id: r.id, epoch: epoch, queue: queue, status: .unsupported)
  let op: GuestBlockOp
  switch r.op {
  case .read: op = .read
  case .write: op = .write
  case .flush: op = .flush
  default: return .unsupported(unsupported)
  }
  guard
    let limits = BlockLimits(
      capacity: capacitySectors, blockBytes: 512, maxVectors: 1,
      flush: features & 512 != 0, fua: false, discard: false, zero: false,
      readOnly: features & 32 != 0)
  else { return .invalid }
  if (op == .flush && !limits.flush) || (op == .write && limits.readOnly) {
    return .unsupported(unsupported)
  }
  guard limits.supports(r) else { return .invalid }
  let vector: BlockDmaVector
  if op == .flush {
    vector = BlockDmaVector(address: 0, bytes: 0)
  } else {
    guard r.payload.vectors == 1, allows(r.payload.list, 16, false),
      var v = readVector(r.payload.list)
    else { return .invalid }
    let valid = withUnsafePointer(to: &v) {
      limits.checkVectors(r, snapshot: UnsafeBufferPointer(start: $0, count: 1), validate: allows)
    }
    guard valid else { return .invalid }
    vector = v
  }
  return .ready(
    PendingBlockIo(
      packet: BlockPacket(
        op: op, sector: r.lba, bytes: vector.bytes,
        header: header, data: vector.address, status: status), id: r.id, epoch: epoch, queue: queue)
  )
}
