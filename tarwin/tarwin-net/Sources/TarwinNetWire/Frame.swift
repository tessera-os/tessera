import TarwinIPC

public enum NetDirection: UInt8 {
  case transmit = 1
  case receive = 2
}
private func get(_ r: borrowing RingRecord, _ n: Int) -> UInt64 {
  UInt64(r.words[n]) | UInt64(r.words[n + 1]) << 32
}
private func put(_ r: inout RingRecord, _ n: Int, _ value: UInt64) {
  r.words[n] = UInt32(truncatingIfNeeded: value)
  r.words[n + 1] = UInt32(value >> 32)
}
private func header(_ r: borrowing RingRecord, used: Int) -> NetDirection? {
  guard r.words[0] & 0xffff_00ff == 1 else { return nil }
  for i in used..<32 where r.words[i] != 0 { return nil }
  return NetDirection(rawValue: UInt8(truncatingIfNeeded: r.words[0] >> 8))
}
public struct NetFrame: Equatable {
  public let direction: NetDirection, queue: UInt32, id: UInt64, epoch: UInt64, iova: UInt64,
    bytes: UInt32
  public init?(
    direction: NetDirection, queue: UInt32, id: UInt64, epoch: UInt64, iova: UInt64, bytes: UInt32
  ) {
    guard id != 0, epoch != 0, bytes >= 14, bytes <= 65553, UInt64(bytes) - 1 <= .max - iova else {
      return nil
    }
    self.direction = direction
    self.queue = queue
    self.id = id
    self.epoch = epoch
    self.iova = iova
    self.bytes = bytes
  }
  public init?(record r: borrowing RingRecord) {
    guard let d = header(r, used: 9) else { return nil }
    self.init(
      direction: d, queue: r.words[1], id: get(r, 2), epoch: get(r, 4), iova: get(r, 6),
      bytes: r.words[8])
  }
  public func record() -> RingRecord {
    var r = RingRecord()
    r.words[0] = 1 | UInt32(direction.rawValue) << 8
    r.words[1] = queue
    put(&r, 2, id)
    put(&r, 4, epoch)
    put(&r, 6, iova)
    r.words[8] = bytes
    return r
  }
}
public struct NetFrameDone: Equatable {
  public let direction: NetDirection, queue: UInt32, id: UInt64, epoch: UInt64, bytes: UInt32
  public init?(direction: NetDirection, queue: UInt32, id: UInt64, epoch: UInt64, bytes: UInt32) {
    guard id != 0, epoch != 0, (14...65553).contains(bytes) else { return nil }
    self.direction = direction
    self.queue = queue
    self.id = id
    self.epoch = epoch
    self.bytes = bytes
  }
  public init?(record r: borrowing RingRecord) {
    guard let d = header(r, used: 7) else { return nil }
    self.init(direction: d, queue: r.words[1], id: get(r, 2), epoch: get(r, 4), bytes: r.words[6])
  }
  public func record() -> RingRecord {
    var r = RingRecord()
    r.words[0] = 1 | UInt32(direction.rawValue) << 8
    r.words[1] = queue
    put(&r, 2, id)
    put(&r, 4, epoch)
    r.words[6] = bytes
    return r
  }
}
