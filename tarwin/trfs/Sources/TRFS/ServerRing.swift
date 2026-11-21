import TarwinFsWire
import TarwinIPC

public typealias FsRecord = TarwinFsWire.FsRecord
public typealias FsOp = TarwinFsWire.FsOp

public struct VolumeNode: Equatable {
  public let volume: UInt64
  public let node: UInt64

  public init(volume: UInt64, node: UInt64) {
    self.volume = volume
    self.node = node
  }
}
public func fsRequestBytes(_ r: FsRecord) -> [UInt8] {
  let record = r.record()
  return (0..<64).map { i in UInt8(truncatingIfNeeded: record.words[i / 4] >> ((i % 4) * 8)) }
}
/// Private, normalized range from the VM share resolver. Views of the same
/// bytes must resolve to the same backing ID and backing-relative offsets.
public struct FsShare: Equatable {
  public let volume: UInt64, id: UInt64, backing: UInt64, offset: UInt64
  public let length: UInt32, writable: Bool
  public init(
    volume: UInt64, id: UInt64, backing: UInt64, offset: UInt64, length: UInt32, writable: Bool
  ) {
    self.volume = volume
    self.id = id
    self.backing = backing
    self.offset = offset
    self.length = length
    self.writable = writable
  }
  fileprivate func overlaps(_ other: FsShare?) -> Bool {
    guard let other else { return false }
    if id == other.id { return true }
    guard backing == other.backing else { return false }
    if offset <= other.offset { return other.offset - offset < UInt64(length) }
    return offset - other.offset < UInt64(other.length)
  }
}
struct FsPending {
  let record: FsRecord
  let source: FsShare?, destination: FsShare?
  func conflicts(_ share: FsShare?) -> Bool {
    guard let share else { return false }
    return share.overlaps(source) || share.overlaps(destination)
  }
}

public struct FsChannel: ~Copyable {
  public let volume: UInt64
  public let epoch: UInt64
  public let limit: Int
  public internal(set) var last: UInt64 = 0
  public internal(set) var live: Int = 0
  var pending: [FsPending] = []
  public internal(set) var disconnected: Bool = false

  // The caller has resolved Node rights for this operation. All Memory
  // grants are kernel-created, server-local, request-exclusive and exact
  // ranges. The VM keeps the resolved backing identity stable until revoke.
  public mutating func begin(
    _ op: FsOp, _ primary: VolumeNode, _ secondary: VolumeNode, _ offset: UInt64, _ input: UInt64,
    _ inBytes: UInt32, _ output: UInt64, _ outBytes: UInt32,
    _ resolveShare: (UInt64) -> FsShare?, _ publish: (FsRecord) -> Bool
  ) -> Bool {
    if volume == 0 || epoch == 0 || disconnected || live >= limit || last == 0xffff_ffff_ffff_ffff
      || primary.volume != volume
      || primary.node == 0
    {
      return false
    }
    if op == .rename || op == .link {
      if secondary.node == 0 || secondary.volume != volume { return false }
    } else if secondary.node != 0 {
      return false
    }
    if (input == 0) != (inBytes == 0) || (output == 0) != (outBytes == 0)
      || (input != 0 && input == output)
    {
      return false
    }
    if op == .read && outBytes > 0 && UInt64(outBytes - 1) > .max - offset { return false }
    if op == .write && inBytes > 0 && UInt64(inBytes - 1) > .max - offset { return false }
    func checked(_ id: UInt64, _ len: UInt32, _ writable: Bool) -> FsShare? {
      guard id != 0, let s = resolveShare(id), s.id == id, s.volume == volume, s.backing != 0,
        s.writable == writable, s.length == len, len != 0, UInt64(len - 1) <= .max - s.offset
      else { return nil }
      return s
    }
    let source = checked(input, inBytes, false)
    let destination = checked(output, outBytes, true)
    guard input == 0 || source != nil, output == 0 || destination != nil,
      source?.overlaps(destination) != true
    else { return false }
    for i in 0..<live where pending[i].conflicts(source) || pending[i].conflicts(destination) {
      return false
    }
    let record = FsRecord(
      op: op, id: last + 1, node: primary.node, other: secondary.node,
      offset: offset, input: input, output: output, inputBytes: inBytes, outputBytes: outBytes)
    if !publish(record) { return false }
    let item = FsPending(record: record, source: source, destination: destination)
    if live == pending.count { pending.append(item) } else { pending[live] = item }
    live += 1
    last += 1
    return true
  }

  // revoke removes access synchronously before the cache exposes bytes.
  public mutating func finish(
    _ sourceEpoch: UInt64, _ id: UInt64, _ produced: UInt32, _ revoke: (FsRecord) -> Bool
  ) -> Bool {
    if disconnected || sourceEpoch != epoch || id == 0 { return false }
    for i in 0..<live {
      let p = pending[i].record
      if p.id == id {
        if produced > p.outputBytes || !revoke(p) { return false }
        live -= 1
        pending[i] = pending[live]
        return true
      }
    }
    return false
  }

  public mutating func disconnect(_ revoke: (FsRecord) -> Bool, _ failPending: (UInt64) -> Void)
    -> Bool
  {
    disconnected = true
    while live > 0 {
      let p = pending[live - 1].record
      if !revoke(p) { return false }
      live -= 1
      failPending(p.id)
    }
    return true
  }

  public init(volume: UInt64, epoch: UInt64, limit: Int) {
    self.volume = volume
    self.epoch = epoch
    self.limit = limit
  }
}
