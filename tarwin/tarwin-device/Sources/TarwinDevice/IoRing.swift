import Synchronization
import TarwinIPC

/// Allocator-facing side of a fresh A.4 device ring. The kernel owns a
/// page-aligned, pinned, coherent Memory mapping, initially exclusive to it.
/// Initialize once, before giving either peer access. Never reset a live ring.
public struct IoRingMapping {
  private let words: UnsafeBufferPointer<Atomic<UInt32>>
  public init?(initializing memory: UnsafeMutableRawBufferPointer, count: UInt32, stride: UInt32) {
    let geometry = RingGeometry(count: count, stride: stride)
    guard MemoryLayout<Atomic<UInt32>>.stride == 4,
      geometry.fits(UInt64(memory.count)), let base = memory.baseAddress,
      UInt(bitPattern: base) & 63 == 0
    else { return nil }
    // All fields and records are native little-endian atomic u32 per TarwinIPC.
    // Only bind the ring, not any trailing VM page slack.
    let n = (Int(RingFormat.records) + 2 * Int(count) * Int(stride)) / 4
    let storage = base.bindMemory(to: Atomic<UInt32>.self, capacity: n)
    for i in 0..<n { storage.advanced(by: i).initialize(to: Atomic(0)) }
    words = UnsafeBufferPointer(start: storage, count: n)
    words[0].store(RingFormat.magic, ordering: .relaxed)
    words[1].store(UInt32(RingFormat.version), ordering: .relaxed)
    words[2].store(count, ordering: .relaxed)
    words[3].store(stride, ordering: .releasing)
  }
  /// Create both sides while quiescent; one serialized owner per role.
  /// Every endpoint borrows the mapping until teardown completes.
  public func endpoint(completion: Bool, producer: Bool) -> RingEndpoint? {
    RingEndpoint(fresh: words, completion: completion, producer: producer)
  }
}
