import Synchronization

// Little-endian atomic U64 words. Do not share Swift aggregate layout.
private enum Word: Int {
  case sequence, header, frequency, origin, active, slept, utcBoot, utcBase, correction, smearStart
}

private let version: UInt64 = 0x3150_4d54_0000_0000
private let wordCount = Word.smearStart.rawValue + 1

@available(macOS 15, *)
private func suitablePage(_ bytes: UnsafeRawBufferPointer) -> Bool {
  guard let p = bytes.baseAddress, bytes.count == 4096 || bytes.count == 16384 else { return false }
  return UInt(bitPattern: p) % UInt(bytes.count) == 0 && MemoryLayout<Atomic<UInt64>>.stride == 8
}

/// Initialize before mapping the frame. Keep it pinned in normal coherent
/// memory, mapped RW/NX only to the kernel and RO/NX to every process.
/// Serialize publication; retire the writer only after the last unmap.
@available(macOS 15, *)
public struct TimePageWriter: ~Copyable {
  private let words: UnsafeMutablePointer<Atomic<UInt64>>

  public init?(freshPage: UnsafeMutableRawBufferPointer) {
    guard suitablePage(.init(freshPage)), let p = freshPage.baseAddress else { return nil }
    freshPage.initializeMemory(as: UInt8.self, repeating: 0)
    words = p.bindMemory(to: Atomic<UInt64>.self, capacity: wordCount)
    for i in 0..<wordCount { (words + i).initialize(to: Atomic(0)) }
  }

  public func publish(_ clock: SystemClocks) -> Bool {
    let seq = words.pointee.load(ordering: .sequentiallyConsistent)
    guard seq & 1 == 0 else { return false }
    words.pointee.store(seq + 1, ordering: .sequentiallyConsistent)
    guard seq < .max - 1 else { return false } // leave exhausted sequence odd
    func set(_ w: Word, _ x: UInt64) {
      words[w.rawValue].store(x, ordering: .sequentiallyConsistent)
    }
    let leap: UInt64 = clock.smear.map { $0.leap == .insertion ? 4 : 8 } ?? 0
    set(.header, version | (clock.suspended ? 2 : 0) | (clock.utcBase == nil ? 0 : 1) | leap)
    set(.frequency, clock.frequency)
    set(.origin, clock.origin)
    set(.active, clock.activeTicks)
    set(.slept, clock.slept)
    set(.utcBoot, clock.utcBoot)
    set(.utcBase, clock.utcBase ?? 0)
    set(.correction, UInt64(bitPattern: clock.correction))
    set(.smearStart, clock.smear?.start ?? 0)
    words.pointee.store(seq + 2, ordering: .sequentiallyConsistent)
    return true
  }

  deinit { words.deinitialize(count: wordCount) }
}

/// Read-only view. The ordered architectural counter read must be in the
/// same domain on every eligible CPU and ordered against the page loads.
/// On persistent interference or during suspend, return nil rather than
/// guessing or spinning indefinitely in user space.
@available(macOS 15, *)
public struct TimePageReader {
  /// First page of the A.2 shared region in a 47-bit user address space.
  public static var address47: UInt64 { (1 << 47) - (1 << 36) }
  private let words: UnsafePointer<Atomic<UInt64>>

  public init?(page: UnsafeRawBufferPointer) {
    guard suitablePage(page), let p = page.baseAddress else { return nil }
    words = p.assumingMemoryBound(to: Atomic<UInt64>.self)
  }

  public func read(counter: () -> UInt64) -> SystemTime? {
    func get(_ w: Word) -> UInt64 {
      words[w.rawValue].load(ordering: .sequentiallyConsistent)
    }
    for _ in 0..<8 {
      let before = get(.sequence)
      if before == 0 || before & 1 != 0 { continue }
      let header = get(.header)
      if header & ~13 != version || header & 12 == 12 {
        if before == get(.sequence) { return nil }
        continue
      }
      let hz = get(.frequency), origin = get(.origin)
      let active = get(.active), slept = get(.slept), anchor = get(.utcBoot)
      let utc = get(.utcBase), correction = get(.correction)
      let smearStart = header & 12 == 0 ? 0 : get(.smearStart)
      let ticks = counter()
      guard before == get(.sequence) else { continue }
      guard var clock = SystemClocks(frequency: hz, counter: origin)
      else { return nil }
      clock.activeTicks = active
      clock.slept = slept
      clock.utcBoot = anchor
      clock.utcBase = header & 1 == 1 ? utc : nil
      clock.correction = Int64(bitPattern: correction)
      if header & 12 != 0 {
        guard header & 1 == 1, smearStart <= .max - LeapSmear.duration else { return nil }
        clock.smear = LeapSmear(start: smearStart, leap: header & 4 != 0 ? .insertion : .deletion)
      }
      return clock.read(counter: ticks)
    }
    return nil
  }
}
