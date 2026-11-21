import TarwinIPC

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

private func get(_ r: borrowing RingRecord, _ i: Int) -> UInt64 {
  UInt64(r.words[i]) | UInt64(r.words[i + 1]) << 32
}
private func put(_ r: inout RingRecord, _ i: Int, _ v: UInt64) {
  r.words[i] = UInt32(truncatingIfNeeded: v)
  r.words[i + 1] = UInt32(v >> 32)
}
extension FsRecord {
  public func record() -> RingRecord {
    var r = RingRecord()
    r.words[0] = 1 | UInt32(op.rawValue) << 16
    put(&r, 2, id)
    put(&r, 4, node)
    put(&r, 6, other)
    put(&r, 8, offset)
    put(&r, 10, input)
    put(&r, 12, output)
    r.words[14] = inputBytes
    r.words[15] = outputBytes
    return r
  }
  public init?(record r: borrowing RingRecord) {
    guard r.words[0] & 0xffff == 1, r.words[1] == 0,
      let op = FsOp(rawValue: UInt16(r.words[0] >> 16))
    else { return nil }
    for i in 16..<32 where r.words[i] != 0 { return nil }
    let id = get(r, 2)
    let node = get(r, 4)
    let other = get(r, 6)
    let off = get(r, 8)
    let input = get(r, 10)
    let out = get(r, 12)
    let n = r.words[14]
    let m = r.words[15]
    guard id != 0, node != 0, (other != 0) == (op == .rename || op == .link),
      (input == 0) == (n == 0), (out == 0) == (m == 0), input == 0 || input != out,
      op != .read || m == 0 || UInt64(m - 1) <= .max - off,
      op != .write || n == 0 || UInt64(n - 1) <= .max - off
    else { return nil }
    self.init(
      op: op, id: id, node: node, other: other, offset: off, input: input, output: out,
      inputBytes: n, outputBytes: m)
  }
}

/// Private volume protocol statuses. The kernel maps them to its own errors;
/// a server does not choose a subsystem, an object handle or a memory address.
public enum FsStatus: UInt16 {
  case ok = 0
  case notFound, denied, invalid, io, noSpace, unsupported, busy, exists, notDirectory, notEmpty,
    readOnly
}
public struct FsReply: Equatable {
  public let epoch: UInt64, id: UInt64, status: FsStatus, produced: UInt32
  public init?(epoch: UInt64, id: UInt64, status: FsStatus, produced: UInt32) {
    guard epoch != 0, id != 0, status == .ok || produced == 0 else { return nil }
    self.epoch = epoch
    self.id = id
    self.status = status
    self.produced = produced
  }
  public func record() -> RingRecord {
    var r = RingRecord()
    r.words[0] = 1 | UInt32(status.rawValue) << 16
    put(&r, 2, id)
    put(&r, 4, epoch)
    r.words[6] = produced
    return r
  }
  public init?(record r: borrowing RingRecord) {
    guard r.words[0] & 0xffff == 1, r.words[1] == 0,
      let status = FsStatus(rawValue: UInt16(r.words[0] >> 16))
    else { return nil }
    for i in 7..<32 where r.words[i] != 0 { return nil }
    self.init(epoch: get(r, 4), id: get(r, 2), status: status, produced: r.words[6])
  }
}
