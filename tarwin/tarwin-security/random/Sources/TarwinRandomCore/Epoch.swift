/// The platform supplies a trusted generation that changes on restore.
/// A physical machine without snapshots is not a VM with an unknown ID.
public enum RandomEpoch: Equatable {
  case physical
  case virtualMachine(low: UInt64, high: UInt64)
  public var available: Bool {
    switch self {
    case .physical: return true
    case .virtualMachine(let lo, let hi): return lo | hi != 0
    }
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
