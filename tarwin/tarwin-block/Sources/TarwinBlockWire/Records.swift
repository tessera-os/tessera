import TarwinIPC

// Private 26.11 driver protocol. These opcodes are neither syscall numbers
// nor public object types. All fields are little endian on supported ISAs.
public enum BlockOp: UInt8 {
  case read = 1
  case write, flush, fua, discard, zero, zone, atomic
}
public enum IoQos: UInt8 {
  case deadline = 1
  case interactive, initiated, standard, utility, background
}
public enum ZoneAction: UInt32 {
  case none = 0
  case open, close, finish, reset
}
public enum BlockStatus: UInt8 {
  case ok = 0
  case media, unsupported, removed
}
public struct BlockDmaVector {
  public let address: UInt64, bytes: UInt32
  public init(address: UInt64, bytes: UInt32) {
    self.address = address
    self.bytes = bytes
  }
}
public struct BlockPayload {
  public let list: UInt64, vectors: UInt32, zone: ZoneAction
  public init(list: UInt64 = 0, vectors: UInt32 = 0, zone: ZoneAction = .none) {
    self.list = list
    self.vectors = vectors
    self.zone = zone
  }
}
func get(_ r: borrowing RingRecord, _ i: Int) -> UInt64 {
  UInt64(r.words[i]) | UInt64(r.words[i + 1]) << 32
}
func set(_ r: inout RingRecord, _ i: Int, _ n: UInt64) {
  r.words[i] = UInt32(truncatingIfNeeded: n)
  r.words[i + 1] = UInt32(n >> 32)
}
public struct BlockRequest {
  public let id: UInt64, epoch: UInt64, lba: UInt64, blocks: UInt64, queue: UInt32
  public let op: BlockOp, qos: IoQos, payload: BlockPayload
  public init?(
    id: UInt64, epoch: UInt64, lba: UInt64, blocks: UInt64, queue: UInt32, op: BlockOp, qos: IoQos,
    payload: BlockPayload
  ) {
    guard id != 0, epoch != 0, (op == .zone) == (payload.zone != .none) else { return nil }
    let data = op == .read || op == .write || op == .fua || op == .atomic
    if data {
      guard payload.vectors > 0, payload.list % 8 == 0,
        UInt64(payload.vectors) * 16 - 1 <= UInt64.max - payload.list
      else { return nil }
    } else if payload.list != 0 || payload.vectors != 0 {
      return nil
    }
    if op == .flush {
      guard blocks == 0, lba == 0 else { return nil }
    } else if blocks == 0 || blocks - 1 > UInt64.max - lba {
      return nil
    }
    self.id = id
    self.epoch = epoch
    self.lba = lba
    self.blocks = blocks
    self.queue = queue
    self.op = op
    self.qos = qos
    self.payload = payload
  }
  public func record() -> RingRecord {
    var r = RingRecord()
    r.words[0] = 1 | UInt32(op.rawValue) << 16 | UInt32(qos.rawValue) << 24
    set(&r, 2, id)
    set(&r, 4, epoch)
    set(&r, 6, lba)
    set(&r, 8, blocks)
    set(&r, 10, payload.list)
    r.words[12] = payload.vectors
    r.words[13] = queue
    r.words[14] = payload.zone.rawValue
    return r
  }
  public init?(record r: borrowing RingRecord, epoch: UInt64, queue: UInt32) {
    guard r.words[0] & 0xffff == 1, r.words[1] == 0, get(r, 4) == epoch, r.words[13] == queue,
      let op = BlockOp(rawValue: UInt8(truncatingIfNeeded: r.words[0] >> 16)),
      let qos = IoQos(rawValue: UInt8(r.words[0] >> 24)),
      let zone = ZoneAction(rawValue: r.words[14])
    else { return nil }
    for i in 15..<32 where r.words[i] != 0 { return nil }
    self.init(
      id: get(r, 2), epoch: epoch, lba: get(r, 6), blocks: get(r, 8), queue: queue, op: op,
      qos: qos,
      payload: BlockPayload(list: get(r, 10), vectors: r.words[12], zone: zone))
  }
}
public struct BlockCompletion {
  public let id: UInt64, epoch: UInt64, queue: UInt32, status: BlockStatus
  public init(id: UInt64, epoch: UInt64, queue: UInt32, status: BlockStatus) {
    self.id = id
    self.epoch = epoch
    self.queue = queue
    self.status = status
  }
  public func record() -> RingRecord {
    var r = RingRecord()
    r.words[0] = 1 | UInt32(status.rawValue) << 16
    r.words[1] = queue
    set(&r, 2, id)
    set(&r, 4, epoch)
    return r
  }
  public init?(record r: borrowing RingRecord) {
    guard r.words[0] & 0xff00_ffff == 1, get(r, 2) != 0, get(r, 4) != 0,
      let status = BlockStatus(rawValue: UInt8(r.words[0] >> 16))
    else { return nil }
    for i in 6..<32 where r.words[i] != 0 { return nil }
    self.init(id: get(r, 2), epoch: get(r, 4), queue: r.words[1], status: status)
  }
}

/// Registration snapshots the device's limits. An unavailable feature must
/// be reported as unsupported, never silently downgraded (notably FUA/atomic).
public struct BlockLimits {
  public let capacity: UInt64, blockBytes: UInt32, maxVectors: UInt32
  public let flush: Bool, fua: Bool, discard: Bool, zero: Bool, readOnly: Bool
  public let atomicUnit: UInt32, zoneBlocks: UInt64
  public init?(
    capacity: UInt64, blockBytes: UInt32, maxVectors: UInt32, flush: Bool, fua: Bool,
    discard: Bool, zero: Bool, readOnly: Bool, atomicUnit: UInt32 = 0, zoneBlocks: UInt64 = 0
  ) {
    guard capacity != 0, blockBytes >= 512, blockBytes.nonzeroBitCount == 1,
      maxVectors > 0, maxVectors <= 65536, UInt64(atomicUnit) <= capacity, zoneBlocks <= capacity
    else { return nil }
    self.capacity = capacity
    self.blockBytes = blockBytes
    self.maxVectors = maxVectors
    self.flush = flush
    self.fua = fua
    self.discard = discard
    self.zero = zero
    self.readOnly = readOnly
    self.atomicUnit = atomicUnit
    self.zoneBlocks = zoneBlocks
  }
  public func supports(_ r: BlockRequest) -> Bool {
    if r.op == .flush { return flush }
    guard r.lba < capacity, r.blocks <= capacity - r.lba, r.payload.vectors <= maxVectors else {
      return false
    }
    if r.op == .read { return true }
    if readOnly { return false }
    switch r.op {
    case .write: return true
    case .fua: return fua
    case .discard: return discard
    case .zero: return zero
    case .atomic:
      return atomicUnit != 0 && r.blocks == UInt64(atomicUnit) && r.lba % UInt64(atomicUnit) == 0
    case .zone:
      return zoneBlocks != 0 && r.lba % zoneBlocks == 0
        && r.blocks == min(zoneBlocks, capacity - r.lba)
    default: return false
    }
  }
  /// Read the vector list ONCE from a pinned, read-only grant into private
  /// storage before calling. validate checks the exact pin, slot and access
  /// direction for both the list and data. No physical-address fallback.
  public func checkVectors(
    _ r: BlockRequest, snapshot: UnsafeBufferPointer<BlockDmaVector>,
    validate: (UInt64, UInt64, Bool) -> Bool
  ) -> Bool {
    guard supports(r), snapshot.count == r.payload.vectors else { return false }
    if snapshot.isEmpty { return true }
    let (expected, overflow) = r.blocks.multipliedReportingOverflow(by: UInt64(blockBytes))
    let listBytes = UInt64(snapshot.count) * 16
    guard !overflow, validate(r.payload.list, listBytes, false) else { return false }
    var remaining = expected
    for s in snapshot {
      let n = UInt64(s.bytes)
      guard n != 0, n <= remaining, n - 1 <= UInt64.max - s.address,
        s.address >= r.payload.list
          ? s.address - r.payload.list >= listBytes : r.payload.list - s.address >= n,
        validate(s.address, n, r.op == .read)
      else { return false }
      remaining -= n
    }
    return remaining == 0
  }
}
