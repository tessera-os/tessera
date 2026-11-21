/// The platform supplies a trusted generation that changes on restore.
/// A physical machine without snapshots is not a VM with an unknown ID.
public enum RandomEpoch: Equatable {
  case physical
  case virtualMachine(low: UInt64, high: UInt64)
  /// Only for an independently enforced, non-restorable debug harness.
  case fixedDebugQEMU(low: UInt64, high: UInt64)

  public var wireWords: (low: UInt64, high: UInt64) {
    switch self {
    case .physical: return (0, 0)
    case .virtualMachine(let lo, let hi), .fixedDebugQEMU(let lo, let hi): return (lo, hi)
    }
  }

  public var available: Bool {
    self == .physical || wireWords.low | wireWords.high != 0
  }
}

/// Per-thread LibTessera state. Seed bytes and their epoch come from the
/// same kernel operation. The shared epoch is read before every request.
public struct ThreadRandomState: ~Copyable {
  private var epoch: RandomEpoch?
  private var stream: ChaChaStream?
  public init() {}
  public mutating func discard() {
    epoch = nil
    stream = nil
  }
  public mutating func replace(seed: UnsafeRawBufferPointer, at generation: RandomEpoch?) -> Bool {
    discard()
    guard let generation, generation.available, let fresh = ChaChaStream(seed: seed) else {
      return false
    }
    stream = consume fresh
    epoch = generation
    return true
  }
  public mutating func fill(_ output: UnsafeMutableRawBufferPointer, current: RandomEpoch?) -> Bool
  {
    guard let current, epoch == current else {
      discard()
      return false
    }
    stream!.fill(output)
    return true
  }
}
