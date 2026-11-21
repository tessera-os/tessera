import TarwinBlockWire
import TarwinIPC

/// Per-request CPU mappings, held pinned through execute(). Both methods
/// reject wrong owners, directions, private pages and physical aliases.
/// Never reinterpret the wire address as a host pointer.
public protocol USBBlockGrants {
  func readable(_ address: UInt64, count: Int) -> UnsafeRawBufferPointer?
  func writable(_ address: UInt64, count: Int) -> UnsafeMutableRawBufferPointer?
}

/// One serialized worker per claimed interface. The bus only sees private
/// bounce buffers, never a client's block vector or mapped page.
public struct USBBlockService: ~Copyable {
  public let limits: BlockLimits, epoch: UInt64
  public let maxBlocks: UInt32
  private var disk: USBDisk

  public init(_ disk: consuming USBDisk, epoch: UInt64) throws {
    guard epoch != 0,
      let limits = BlockLimits(
        capacity: disk.blocks,
        blockBytes: UInt32(disk.blockBytes), maxVectors: 32, flush: true,
        fua: disk.forceUnitAccess && !disk.readOnly, discard: disk.maxDiscardBlocks != 0,
        zero: false,
        readOnly: disk.readOnly)
    else { throw StorageError.bounds }
    self.maxBlocks = UInt32(BulkOnly.limit / disk.blockBytes)
    self.limits = limits
    self.epoch = epoch
    self.disk = consume disk
  }

  /// Malformed records have no trusted completion address. Valid records
  /// always yield a terminal result (including failures); never replay them.
  public mutating func execute(_ record: borrowing RingRecord, grants: some USBBlockGrants)
    -> BlockCompletion?
  {
    guard let r = BlockRequest(record: record, epoch: epoch, queue: 0) else { return nil }
    func done(_ status: BlockStatus) -> BlockCompletion {
      BlockCompletion(id: r.id, epoch: r.epoch, queue: r.queue, status: status)
    }
    let maximum = r.op == .discard ? disk.maxDiscardBlocks : maxBlocks
    guard limits.supports(r), r.blocks <= UInt64(maximum) else { return done(.unsupported) }
    do {
      if r.op == .flush {
        try disk.flush()
        return done(.ok)
      }
      if r.op == .discard {
        try disk.discard(lba: r.lba, blocks: UInt32(r.blocks))
        return done(.ok)
      }
      let bytes = Int(r.blocks) * Int(limits.blockBytes)
      let listBytes = Int(r.payload.vectors) * 16
      guard let list = grants.readable(r.payload.list, count: listBytes), list.count == listBytes
      else { return done(.media) }
      // Inspect only our snapshot, including reserved fields.
      let wire = Array(list)
      var vectors: [BlockDmaVector] = []
      for i in stride(from: 0, to: listBytes, by: 16) {
        let address = wire[i..<i + 8].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let count = wire[i + 8..<i + 12].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard wire[i + 12..<i + 16].allSatisfy({ $0 == 0 }),
          vectors.allSatisfy({ v in
            v.address <= address
              ? address - v.address >= UInt64(v.bytes)
              : v.address - address >= UInt64(count)
          })
        else { return done(.media) }
        vectors.append(BlockDmaVector(address: address, bytes: count))
      }
      var sources: [UnsafeRawBufferPointer] = []
      var destinations: [UnsafeMutableRawBufferPointer] = []
      let valid = vectors.withUnsafeBufferPointer { snapshot in
        limits.checkVectors(r, snapshot: snapshot) { address, length, writing in
          if address == r.payload.list { return !writing && length == listBytes }
          if writing {
            guard let dest = grants.writable(address, count: Int(length)), dest.count == length
            else { return false }
            destinations.append(dest)
          } else {
            guard let src = grants.readable(address, count: Int(length)), src.count == length
            else { return false }
            sources.append(src)
          }
          return true
        }
      }
      guard valid else { return done(.media) }
      let blocks = UInt32(r.blocks)
      switch r.op {
      case .read:
        let data = try disk.read(lba: r.lba, blocks: blocks)
        data.withUnsafeBytes { raw in
          var offset = 0
          for dest in destinations {
            dest.copyMemory(from: .init(rebasing: raw[offset..<offset + dest.count]))
            offset += dest.count
          }
        }
      case .write, .fua:
        var data: [UInt8] = []
        data.reserveCapacity(bytes)
        for source in sources { data.append(contentsOf: source) }
        try disk.write(lba: r.lba, blocks: blocks, data: data, fua: r.op == .fua)
      default: return done(.unsupported)
      }
      return done(.ok)
    } catch StorageError.detached { return done(.removed) } catch { return done(.media) }
  }
}
