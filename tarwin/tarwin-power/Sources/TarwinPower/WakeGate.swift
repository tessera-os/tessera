import Synchronization

public enum WakeCause: UInt64 {
  case interrupt = 2
  case timer, networkPattern, policyChange
}

/// One pinned gate per suspend controller. Its address remains stable until
/// the last wake-source callback and pending platform kick have drained.
public struct WakeGate: ~Copyable, Sendable {
  private let word = Atomic<UInt64>(0)
  public init() {}

  func arm() -> UInt64? {
    let old = word.load(ordering: .acquiring)
    guard old & 7 == 0, old <= UInt64.max - 9 else { return nil }
    let token = old + 9
    guard
      word.compareExchange(expected: old, desired: token, ordering: .acquiringAndReleasing)
        .exchanged
    else { return nil }
    return token
  }
  public func armed(_ token: UInt64) -> Bool {
    token & 7 == 1 && word.load(ordering: .acquiring) == token
  }
  /// Only a validated, still registered wake source may call this. The
  /// platform kick must stay pending across the final check-to-idle gap.
  @discardableResult public func signal(_ token: UInt64, cause: WakeCause, kick: () -> Void) -> Bool
  {
    guard token & 7 == 1,
      word.compareExchange(
        expected: token, desired: (token & ~7) | cause.rawValue,
        ordering: .acquiringAndReleasing
      ).exchanged
    else { return false }
    kick()
    return true
  }
  func cause(_ token: UInt64) -> WakeCause? {
    let state = word.load(ordering: .acquiring)
    guard token & 7 == 1, state >> 3 == token >> 3 else { return nil }
    return WakeCause(rawValue: state & 7)
  }
  // Serialized by the sole controller after all wake producers have drained.
  func retire(_ token: UInt64) {
    word.store(token & ~7, ordering: .releasing)
  }
}
