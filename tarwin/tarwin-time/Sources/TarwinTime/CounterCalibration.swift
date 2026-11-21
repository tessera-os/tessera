/// Ordered reads on one CPU: arch counter, reference (ns), arch counter.
/// An RTC being used as a reference must not be stepped during calibration.
public struct CounterCrossStamp {
  public let before, referenceNS, after: UInt64
  public init?(before: UInt64, referenceNS: UInt64, after: UInt64) {
    guard before <= after else { return nil }
    self.before = before
    self.referenceNS = referenceNS
    self.after = after
  }
}

/// Corroborate the firmware rate. Both extremes of the *possible* interval
/// must agree with the reference at nanosecond resolution: a slow MMIO read
/// or preemption is not evidence for a guessed midpoint. The platform picks
/// a minimum duration and error budget for its reference, including its
/// resolution. Do not retry indefinitely or publish a failed calibration.
public struct BootCounterRate {
  public let frequency: UInt64
  public init?(
    advertisedHz: UInt64, first: CounterCrossStamp, last: CounterCrossStamp,
    minimumNS: UInt64, maximumErrorNS: UInt64
  ) {
    guard advertisedHz != 0, minimumNS > maximumErrorNS, last.before > first.after,
      last.referenceNS > first.referenceNS else { return nil }
    let interval = last.referenceNS - first.referenceNS
    guard interval >= minimumNS else { return nil }
    func matches(_ ticks: UInt64) -> Bool {
      let d = counterDuration(ticks, frequency: advertisedHz)
      guard d.valid else { return false }
      return (d.ns < interval ? interval - d.ns : d.ns - interval) <= maximumErrorNS
    }
    guard matches(last.before - first.after), matches(last.after - first.before) else { return nil }
    frequency = advertisedHz
  }
}

/// Cross-CPU diagnostic for an architectural counter specified to have a
/// common epoch. A rendezvous contains the remote ordered read between two
/// local ordered reads, joined by release/acquire messages. Reject skew
/// outside that bracket and ambiguous (wide) observations. This does not
/// synthesize a clock offset, or establish synchronization for future time.
public struct CounterRendezvous {
  public let before, peer, after: UInt64
  public init?(before: UInt64, peer: UInt64, after: UInt64, maximumSpan: UInt64) {
    guard before <= peer, peer <= after, after - before <= maximumSpan else { return nil }
    self.before = before
    self.peer = peer
    self.after = after
  }

  public func follows(_ first: Self, minimumTicks: UInt64) -> Bool {
    minimumTicks > 0 && before > first.after && before - first.after >= minimumTicks && peer > first.peer
  }
}
