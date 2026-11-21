import TarwinBlockWire

/// Serves the Tarwin block driver protocol against a hosted disk image.
/// tarwind gives it each validated request and the request's DMA vectors;
/// `map` turns one vector (address, bytes, deviceWrites) into host memory
/// already pinned and granted for that direction, or nil to refuse.
public final class HostedBlockDriver: @unchecked Sendable {
  public let device: HostedBlockDevice
  public let limits: BlockLimits
  public typealias Map = (UInt64, UInt64, Bool) -> UnsafeMutableRawBufferPointer?

  public init(device: HostedBlockDevice, maxVectors: UInt32 = 256) {
    self.device = device
    limits = BlockLimits(
      capacity: device.blocks, blockBytes: UInt32(HostedBlockDevice.blockBytes),
      maxVectors: maxVectors, flush: true, fua: true, discard: !device.readOnly,
      zero: !device.readOnly, readOnly: device.readOnly)!
  }

  public func serve(
    _ r: BlockRequest, vectors: UnsafeBufferPointer<BlockDmaVector>, map: Map
  ) -> BlockCompletion {
    BlockCompletion(id: r.id, epoch: r.epoch, queue: r.queue, status: run(r, vectors, map))
  }

  private func run(
    _ r: BlockRequest, _ vectors: UnsafeBufferPointer<BlockDmaVector>, _ map: Map
  ) -> BlockStatus {
    guard limits.supports(r) else { return .unsupported }
    switch r.op {
    case .flush: return device.flush() ? .ok : .media
    case .discard: return device.discard(r.lba, count: r.blocks) ? .ok : .media
    case .zero: return device.zero(r.lba, count: r.blocks) ? .ok : .media
    case .read, .write, .fua:
      guard vectors.count == Int(r.payload.vectors) else { return .unsupported }
      let bs = UInt64(HostedBlockDevice.blockBytes)
      var total: UInt64 = 0
      for v in vectors {
        guard v.bytes != 0, UInt64(v.bytes) % bs == 0 else { return .unsupported }
        total += UInt64(v.bytes)
      }
      guard total == r.blocks * bs else { return .unsupported }
      var lba = r.lba
      for v in vectors {
        guard let mem = map(v.address, UInt64(v.bytes), r.op == .read),
          mem.count == Int(v.bytes)
        else { return .unsupported }
        let ok = r.op == .read ? device.read(lba, into: mem) : device.write(lba, from: .init(mem))
        guard ok else { return .media }
        lba += UInt64(v.bytes) / bs
      }
      if r.op == .fua && !device.flush() { return .media }
      return .ok
    default: return .unsupported
    }
  }
}
