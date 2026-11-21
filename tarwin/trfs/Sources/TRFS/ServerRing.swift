// A.5 request records use volume-local numbers, never process handles or
// addresses. One locked channel belongs to one server instance and volume.
public enum FsOp: UInt16, Equatable {
  case lookup = 1
  case getAttributes = 2
  case setAttributes = 3
  case read = 4
  case write = 5
  case create = 6
  case remove = 7
  case rename = 8
  case readDirectory = 9
  case link = 10
  case symbolicLink = 11
  case readLink = 12
  case flush = 13
  case sync = 14
  case statFileSystem = 15
  case watch = 16
  case getXattr = 17
  case setXattr = 18
  case listXattr = 19
  case removeXattr = 20
}

public struct VolumeNode: Equatable {
  public let volume: UInt64
  public let node: UInt64

  public init(volume: UInt64, node: UInt64) {
    self.volume = volume
    self.node = node
  }
}
public struct FsRecord: Equatable {
  public let op: FsOp
  public let id: UInt64
  public let node: UInt64
  public let other: UInt64
  public let offset: UInt64
  public let input: UInt64
  public let output: UInt64
  public let inputBytes: UInt32
  public let outputBytes: UInt32

  public init(
    op: FsOp, id: UInt64, node: UInt64, other: UInt64, offset: UInt64, input: UInt64,
    output: UInt64, inputBytes: UInt32, outputBytes: UInt32
  ) {
    self.op = op
    self.id = id
    self.node = node
    self.other = other
    self.offset = offset
    self.input = input
    self.output = output
    self.inputBytes = inputBytes
    self.outputBytes = outputBytes
  }
}

func putLe(_ bytes: inout [UInt8], _ at: Int, _ width: Int, _ value: UInt64) {
  for i in 0..<width { bytes[at + i] = UInt8((value >> UInt64(8 * i)) & 255) }
}

public func fsRequestBytes(_ r: FsRecord) -> [UInt8] {
  var bytes: [UInt8] = []
  for i in 0..<64 { bytes.append(0) }
  putLe(&bytes, 0, 2, 1)
  putLe(&bytes, 2, 2, UInt64(r.op.rawValue))
  putLe(&bytes, 8, 8, r.id)
  putLe(&bytes, 16, 8, r.node)
  putLe(&bytes, 24, 8, r.other)
  putLe(&bytes, 32, 8, r.offset)
  putLe(&bytes, 40, 8, r.input)
  putLe(&bytes, 48, 8, r.output)
  putLe(&bytes, 56, 4, UInt64(r.inputBytes))
  putLe(&bytes, 60, 4, UInt64(r.outputBytes))
  return bytes
}

public struct FsChannel: Equatable {
  public let volume: UInt64
  public let epoch: UInt64
  public let limit: Int
  public internal(set) var last: UInt64 = 0
  public internal(set) var live: Int = 0
  public internal(set) var pending: [FsRecord] = []
  public internal(set) var disconnected: Bool = false

  // The caller has resolved Node rights for this operation. All Memory
  // grants are kernel-created, server-local, request-exclusive and exact
  // ranges. validateShare checks their volume, direction and length.
  public mutating func begin(
    _ op: FsOp, _ primary: VolumeNode, _ secondary: VolumeNode, _ offset: UInt64, _ input: UInt64,
    _ inBytes: UInt32, _ output: UInt64, _ outBytes: UInt32,
    _ validateShare: (UInt64, UInt64, UInt32, Bool) -> Bool, _ publish: (FsRecord) -> Bool
  ) -> Bool {
    if disconnected || live >= limit || last == 0xffff_ffff_ffff_ffff || primary.volume != volume
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
    if input != 0 && !validateShare(volume, input, inBytes, false) { return false }
    if output != 0 && !validateShare(volume, output, outBytes, true) { return false }
    for i in 0..<live {
      let p = pending[i]
      if input != 0 && (p.input == input || p.output == input) { return false }
      if output != 0 && (p.input == output || p.output == output) { return false }
    }
    let record = FsRecord(
      op: op, id: last + 1, node: primary.node, other: secondary.node,
      offset: offset, input: input, output: output, inputBytes: inBytes, outputBytes: outBytes)
    if !publish(record) { return false }
    if live == pending.count { pending.append(record) } else { pending[live] = record }
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
      let p = pending[i]
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
      let p = pending[live - 1]
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
