/// Absolute Boot-clock nanoseconds. The running CPU converts this to its
/// per-CPU comparator; deep sleep requires an independent wake alarm.
/// Unavailable means refuse to park, never silently discard a wake source.
public enum TimerWakePlan: Equatable {
  case none, atBoot(UInt64), unavailable

  public func including(_ other: Self) -> Self {
    switch (self, other) {
    case (.unavailable, _), (_, .unavailable): .unavailable
    case (.none, _): other
    case (_, .none): self
    case (.atBoot(let x), .atBoot(let y)): .atBoot(min(x, y))
    }
  }
}

extension SystemClocks {
  /// Invert the actual UTC interpolation, not a 1:1 offset estimate. The
  /// map is nondecreasing even during a negative slew. A nil reading above
  /// the anchor is an overflow, not a time earlier than the target.
  func bootForUTC(_ target: UInt64, at now: SystemTime) -> UInt64? {
    guard let utc = now.utc else { return nil }
    if target <= utc { return now.boot }
    if smear == nil && correction.magnitude <= (now.boot - utcBoot) / 2000 {
      let delta = target - utc
      return delta <= .max - now.boot ? now.boot + delta : nil
    }
    var low = now.boot, high = UInt64.max
    while low < high {
      let mid = low + (high - low) / 2
      if let value = wallTime(mid), value < target { low = mid + 1 }
      else { high = mid }
    }
    guard let value = wallTime(low), value >= target else { return nil }
    return low
  }

  public func compareValue(forBoot deadline: UInt64, counter: UInt64) -> UInt64? {
    guard let now = read(counter: counter) else { return nil }
    if deadline <= now.boot { return counter }
    return compareValue(forMonotonic: deadline - (now.boot - now.monotonic), counter: counter)
  }
}

extension OneShotTimers {
  /// Replan under the owner lock after arm/cancel, a clock step or slew,
  /// suspend admission and resume. A future Monotonic wake-source cannot
  /// expire while Monotonic is stopped; refuse sleep rather than substitute
  /// Boot time or deliver it early.
  public func nextWake(
    clock: SystemClocks, counter: UInt64, preparingSleep: Bool
  ) -> TimerWakePlan {
    guard let limit = nextLimit, !preparingSleep || wakesSystem else { return .none }
    guard let now = clock.read(counter: counter) else { return .unavailable }
    switch domain {
    case .monotonic:
      if preparingSleep {
        return hasDue(at: now.monotonic) ? .atBoot(now.boot) : .unavailable
      }
      let delta = limit <= now.monotonic ? 0 : limit - now.monotonic
      return delta <= .max - now.boot ? .atBoot(now.boot + delta) : .unavailable
    case .boot: return .atBoot(max(now.boot, limit))
    case .utc:
      if let boot = clock.bootForUTC(limit, at: now) { return .atBoot(boot) }
      return .unavailable
    }
  }
}
