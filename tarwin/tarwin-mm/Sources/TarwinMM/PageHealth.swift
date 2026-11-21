/// Dispositions are consumed under the allocator/reverse-map lock.
/// Retirement prevents reuse, not access through an existing mapping.
public enum PageErrorAction: Equatable {
  case notManaged, counted, retiredFree, evacuate, alreadyPoisoned, terminateUserMappings, kernelPanic
}

public enum FrameUse { case userMappingsOnly, kernelOrUnknown }

/// Own one physical leaf and its 64 private, initialized counter slots for
/// the lifetime of that RAM. The caller serializes reports, mapping changes
/// and allocation. Do not reconstruct an arena over retired pages.
public struct MonitoredPageArena: ~Copyable {
  private var arena: PageArena
  private let counts: UnsafeMutableBufferPointer<UInt32>
  private let threshold: UInt32
  private var poisoned: UInt64 = 0
  public var base: UInt64 { arena.base }
  public var pageSize: UInt64 { arena.pageSize }
  var hasAllocations: Bool { arena.occupied != 0 }
  func hasSeparateCounters(from bytes: UnsafeMutableRawBufferPointer) -> Bool {
    let a = UInt(bitPattern: counts.baseAddress), b = UInt(bitPattern: bytes.baseAddress)
    return a <= b ? UInt(counts.count * MemoryLayout<UInt32>.stride) <= b - a : UInt(bytes.count) <= a - b
  }

  public init?(fresh arena: consuming PageArena, counts: UnsafeMutableBufferPointer<UInt32>,
    threshold: UInt32) {
    guard arena.usable != 0, arena.occupied == 0, arena.retired == 0,
      counts.count == 64, threshold < .max else { return nil }
    for i in counts.indices { counts[i] = 0 }
    self.arena = consume arena
    self.counts = counts
    self.threshold = threshold
  }

  public mutating func take(order: UInt8) -> Allocation { takePages(&arena, order: order) }

  /// Only after every CPU/device mapping of the allocation has been revoked
  /// and drained. Freeing an enclosing block never un-retires a page in it.
  public mutating func give(address: UInt64, order: UInt8) -> Bool {
    givePages(&arena, address: address, order: order)
  }

  private func index(_ physical: UInt64) -> Int? {
    guard physical >= arena.base else { return nil }
    let i = (physical - arena.base) / arena.pageSize
    guard i < 64, arena.usable & (1 << i) != 0 else { return nil }
    return Int(i)
  }

  public func correctedCount(at physical: UInt64) -> UInt32? {
    guard let i = index(physical) else { return nil }
    return counts[i]
  }

  public mutating func corrected(at physical: UInt64) -> PageErrorAction {
    guard let i = index(physical) else { return .notManaged }
    if counts[i] < .max { counts[i] += 1 }
    let bit = UInt64(1) << i
    if poisoned & bit != 0 { return .alreadyPoisoned }  // Never copy data after a fatal report.
    guard counts[i] > threshold || arena.retired & bit != 0 else { return .counted }
    arena.retired |= bit
    return arena.occupied & bit == 0 ? .retiredFree : .evacuate
  }

  /// Classify from authoritative reverse mappings, never from the privilege
  /// of the faulting instruction. Unknown, mixed or kernel owners must panic.
  /// The caller must escalate an unmanaged fatal error to its actual owner.
  public mutating func uncorrectable(at physical: UInt64, use: (UInt64) -> FrameUse) -> PageErrorAction {
    guard let i = index(physical) else { return .notManaged }
    let bit = UInt64(1) << i
    poisoned |= bit
    arena.retired |= bit
    guard arena.occupied & bit != 0 else { return .retiredFree }
    return use(arena.base + UInt64(i) * arena.pageSize) == .userMappingsOnly
      ? .terminateUserMappings : .kernelPanic
  }
}
