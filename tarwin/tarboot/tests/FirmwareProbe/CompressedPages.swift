import KCore
import TarwinMM

private struct Frame: ByteBuffer {
  let bytes: UnsafeMutableBufferPointer<UInt8>
  func byteCount() -> UInt64 { UInt64(bytes.count) }
  func byteAt(_ offset: UInt64) -> UInt8 { bytes[Int(offset)] }
  mutating func putByte(_ offset: UInt64, value: UInt8) { bytes[Int(offset)] = value }
  func fill(_ seed: UInt8) {
    for i in bytes.indices { bytes[i] = seed ^ UInt8(truncatingIfNeeded: i) }
  }
  func matches(_ seed: UInt8) -> Bool {
    for i in bytes.indices where bytes[i] != seed ^ UInt8(truncatingIfNeeded: i) { return false }
    return true
  }
}

// ExitBootServices transferred these reserved pages. They have no user PTEs,
// active CPU borrowers or DMA mappings; the single owner can release them.
func checkCompression(_ arena: inout MonitoredPageArena, pageSize: UInt64) -> Bool {
  func frame(_ allocation: Allocation) -> Frame? {
    guard allocation.ok, let p = UnsafeMutablePointer<UInt8>(bitPattern: UInt(allocation.address))
    else { return nil }
    p.initialize(repeating: 0, count: Int(pageSize))
    return Frame(bytes: .init(start: p, count: Int(pageSize)))
  }
  let segment = arena.take(order: 0), scratch = arena.take(order: 1)
  guard let storage = frame(segment), scratch.ok,
    let dictionary = UnsafeMutablePointer<UInt16>(bitPattern: UInt(scratch.address)) else { return false }
  dictionary.initialize(repeating: 0, count: 4096)
  var meta = InlineArray<2, CompressedSlot>(repeating: .init())
  return withUnsafeMutableBytes(of: &meta) {
    guard var pool = CompressedSegment(identity: 1, storage: storage.bytes, slots: $0.bindMemory(to: CompressedSlot.self)),
      var table = PageMatchTable(.init(start: dictionary, count: 4096)) else { return false }
    let a = arena.take(order: 0), b = arena.take(order: 0)
    guard let left = frame(a), let right = frame(b) else { return false }
    left.fill(0x35); right.fill(0x79)
    guard let x = pool.store(left, tagged: false, table: &table),
      let y = pool.store(right, tagged: false, table: &table),
      UInt64(pool.usedBytes) < pageSize else { return false }
    left.bytes.baseAddress!.deinitialize(count: Int(pageSize))
    right.bytes.baseAddress!.deinitialize(count: Int(pageSize))
    guard arena.give(address: a.address, order: 0), arena.give(address: b.address, order: 0) else { return false }
    // Immediately reuse and overwrite both original frames; the fault
    // destinations below must not alias either of them or the stored blocks.
    let reuseA = arena.take(order: 0), reuseB = arena.take(order: 0)
    guard reuseA.address == a.address, reuseB.address == b.address,
      let overwrittenA = frame(reuseA), let overwrittenB = frame(reuseB) else { return false }
    overwrittenA.fill(0xf3); overwrittenB.fill(0xd7)
    let fresh = arena.take(order: 0)
    guard var restored = frame(fresh), pool.restore(x, into: &restored, tagged: false), restored.matches(0x35),
      pool.discard(x), !pool.restore(x, into: &restored, tagged: false),
      pool.restore(y, into: &restored, tagged: false), restored.matches(0x79),
      pool.discard(y), pool.usedBytes == 0, overwrittenA.matches(0xf3), overwrittenB.matches(0xd7)
    else { return false }
    for i in overwrittenA.bytes.indices {
      overwrittenA.bytes[i] = 0
      overwrittenB.bytes[i] = 0
      restored.bytes[i] = 0
      storage.bytes[i] = 0
    }
    overwrittenA.bytes.baseAddress!.deinitialize(count: Int(pageSize))
    overwrittenB.bytes.baseAddress!.deinitialize(count: Int(pageSize))
    restored.bytes.baseAddress!.deinitialize(count: Int(pageSize))
    storage.bytes.baseAddress!.deinitialize(count: Int(pageSize))
    dictionary.deinitialize(count: 4096)
    return arena.give(address: reuseA.address, order: 0) && arena.give(address: reuseB.address, order: 0)
      && arena.give(address: fresh.address, order: 0) && arena.give(address: segment.address, order: 0)
      && arena.give(address: scratch.address, order: 1)
  }
}
