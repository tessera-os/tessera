public struct DurationResult {
  public internal(set) var valid: Bool
  public internal(set) var ns: UInt64
}

// floor(remainder * 10^9 / frequency) without a double-width multiply.
// At every prefix of the multiplier we retain the quotient and residue.
// Adding modulo frequency by subtraction also works above 2^63 Hz.
func fractionalNs(_ remainder: UInt64, frequency: UInt64) -> UInt64 {
  var residue: UInt64 = 0
  var quotient: UInt64 = 0
  var bit = UInt64(1) << 29
  while bit != 0 {
    quotient += quotient
    if residue >= frequency - residue {
      residue -= frequency - residue
      quotient += 1
    } else {
      residue += residue
    }
    if (UInt64(1_000_000_000) & bit) != 0 {
      if residue >= frequency - remainder {
        residue -= frequency - remainder
        quotient += 1
      } else {
        residue += remainder
      }
    }
    bit = bit >> 1
  }
  return quotient
}

public func counterDuration(_ ticks: UInt64, frequency: UInt64) -> DurationResult {
  if frequency == 0 { return DurationResult(valid: false, ns: 0) }
  let seconds = ticks / frequency
  if seconds > UInt64(0xffff_ffff_ffff_ffff) / 1_000_000_000 {
    return DurationResult(valid: false, ns: 0)
  }
  let base = seconds * 1_000_000_000
  let rem = ticks % frequency
  var tail: UInt64 = 0
  if rem <= UInt64(0xffff_ffff_ffff_ffff) / 1_000_000_000 {
    tail = (rem * 1_000_000_000) / frequency
  } else {
    tail = fractionalNs(rem, frequency: frequency)
  }
  if tail > UInt64(0xffff_ffff_ffff_ffff) - base { return DurationResult(valid: false, ns: 0) }
  return DurationResult(valid: true, ns: base + tail)
}

// The service can slew UTC by at most 500 ppm of elapsed real time.
// Return the permitted magnitude (the caller retains the correction's sign).
public func utcSlewLimit(_ correction: UInt64, elapsed: UInt64) -> UInt64 {
  let allowed = elapsed / 2000
  return correction < allowed ? correction : allowed
}

public func backgroundSlack(_ interval: UInt64) -> UInt64 {
  let fraction = interval / 10
  return fraction < 1_000_000_000 ? fraction : 1_000_000_000
}

// Prefer an existing programmed wakeup, but never fire early or past slack.
public func coalesceDeadline(_ deadline: UInt64, slack: UInt64, programmed: UInt64) -> UInt64 {
  if programmed >= deadline && programmed - deadline <= slack { return programmed }
  return deadline
}

// Timestamps from the same monotonic epoch, in ns. Sleep/park intervals
// are excluded by resetting both heartbeats when bringing the CPU online.
public func lockupCode(_ now: UInt64, lastScheduled: UInt64, lastInterrupt: UInt64) -> UInt32 {
  if now >= lastInterrupt && now - lastInterrupt >= 20_000_000_000 { return 6 }
  if now >= lastScheduled && now - lastScheduled >= 10_000_000_000 { return 6 }
  return 0
}
