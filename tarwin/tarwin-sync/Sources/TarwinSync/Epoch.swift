import Synchronization

/// Remove a batch from publication before starting its grace period.
/// Retirements after the flip belong to a later batch.
public struct EpochDomain: ~Copyable, Sendable {
  // Bit zero: grace period in flight. Bit one: current reader bank.
  private let state = Atomic<UInt64>(0)
  private let even = Atomic<UInt64>(0)
  private let odd = Atomic<UInt64>(0)
  public init() {}

  public borrowing func withRead<R>(_ body: () -> R) -> R {
    while true {
      let epoch = state.load(ordering: .sequentiallyConsistent) >> 1
      if epoch & 1 == 0 {
        even.wrappingAdd(1, ordering: .sequentiallyConsistent)
        defer { even.wrappingSubtract(1, ordering: .sequentiallyConsistent) }
        if state.load(ordering: .sequentiallyConsistent) >> 1 == epoch { return body() }
      } else {
        odd.wrappingAdd(1, ordering: .sequentiallyConsistent)
        defer { odd.wrappingSubtract(1, ordering: .sequentiallyConsistent) }
        if state.load(ordering: .sequentiallyConsistent) >> 1 == epoch { return body() }
      }
    }
  }

  /// A successful caller owns the ticket for this batch. If another
  /// period is in flight, keep the batch unpublished and retry later.
  public borrowing func beginGracePeriod() -> UInt64? {
    let before = state.load(ordering: .sequentiallyConsistent)
    guard before & 1 == 0, before <= UInt64.max - 3 else { return nil }
    let ticket = before + 3
    return state.compareExchange(
      expected: before, desired: ticket, ordering: .sequentiallyConsistent
    ).exchanged ? ticket : nil
  }

  /// True exactly once for a given batch, and only after all readers that
  /// might have observed it have exited. New readers do not delay it.
  public borrowing func finishGracePeriod(_ ticket: UInt64) -> Bool {
    guard ticket & 1 == 1, state.load(ordering: .sequentiallyConsistent) == ticket else {
      return false
    }
    let readers =
      ticket & 2 != 0
      ? even.load(ordering: .sequentiallyConsistent) : odd.load(ordering: .sequentiallyConsistent)
    guard readers == 0 else { return false }
    return state.compareExchange(
      expected: ticket, desired: ticket - 1, ordering: .sequentiallyConsistent
    ).exchanged
  }
}
