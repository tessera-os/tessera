/// A serialized, read-only test backend for the 26.11 block wire protocol.
/// The VMM supplies three disjoint buffers; only the first is guest mapped.
public struct ReadOnlyBlockGrant {
  public private(set) var lastID: UInt64 = 0
  public init() {}

  public mutating func read(
    grant: UnsafeMutableRawBufferPointer, scratch: UnsafeMutableRawBufferPointer,
    disk: UnsafeRawBufferPointer
  ) -> Bool {
    guard grant.count == 8192, scratch.count == 8192, disk.count == 2048 * 512 else { return false }
    for i in 0..<128 { scratch[i] = grant[i] }
    for i in 256..<272 { scratch[i] = grant[i] }
    func word(_ base: Int, _ count: Int) -> UInt64 {
      var result: UInt64 = 0
      for i in 0..<count { result |= UInt64(scratch[base + i]) << (8 * i) }
      return result
    }
    let id = word(8, 8), lba = word(24, 8)
    guard word(0, 2) == 1, scratch[2] == 1, scratch[3] >= 1, scratch[3] <= 6,
      word(4, 4) == 0, id > lastID, word(16, 8) == 1, lba <= 2040, lba % 8 == 0,
      word(32, 8) == 8, word(40, 8) == 256, word(48, 4) == 1,
      word(256, 8) == 4096, word(264, 4) == 4096, word(268, 4) == 0
    else { return false }
    for i in 52..<128 where scratch[i] != 0 { return false }
    for i in 0..<4096 { scratch[4096 + i] = disk[Int(lba) * 512 + i] }
    for i in 128..<256 { scratch[i] = 0 }
    scratch[128] = 1 // version 1, status OK, queue 0
    for i in 8..<24 { scratch[128 + i] = scratch[i] }
    for i in 4096..<8192 { grant[i] = scratch[i] }
    for i in 128..<256 { grant[i] = scratch[i] }
    lastID = id
    return true
  }
}
