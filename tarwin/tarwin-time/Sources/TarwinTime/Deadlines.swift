/// Earliest integral tick whose nanosecond timestamp reaches the target.
/// Split both factors so no full-width division runtime is needed.
public func deadlineTicks(_ ns: UInt64, frequency: UInt64) -> UInt64? {
  let scale: UInt64 = 1_000_000_000
  guard frequency != 0 else { return nil }
  let seconds = ns / scale, fraction = ns % scale
  guard seconds <= .max / frequency else { return nil }
  let base = seconds * frequency
  let product = fraction * (frequency % scale)
  let tail = fraction * (frequency / scale) + (product + scale - 1) / scale
  return tail <= .max - base ? base + tail : nil
}

extension SystemClocks {
  /// Absolute counter comparator for a monotonic deadline in this running
  /// epoch. Recompute after resume. A past deadline is due immediately.
  public func compareValue(forMonotonic deadline: UInt64, counter: UInt64) -> UInt64? {
    guard let now = read(counter: counter) else { return nil }
    if now.monotonic >= deadline { return counter }
    guard let target = deadlineTicks(deadline, frequency: frequency), target >= activeTicks,
      target - activeTicks <= .max - origin else { return nil }
    return origin + (target - activeTicks)
  }
}
