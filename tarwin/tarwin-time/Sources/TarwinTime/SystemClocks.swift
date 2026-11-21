/// Nanoseconds. UTC is absent until the clock service supplies a trusted
/// wall time, and is unavailable if that clock alone overflows.
public struct SystemTime {
  public let monotonic, boot: UInt64
  public let utc: UInt64?
}

/// Parameters for one calibrated, synchronized counter domain. Keep the
/// kernel copy under the clock writer lock; users read a published copy.
public struct SystemClocks {
  var frequency, origin, activeTicks, slept: UInt64
  var utcBoot: UInt64, utcBase: UInt64?, correction: Int64
  var smear: LeapSmear?
  var suspended: Bool

  public init?(frequency: UInt64, counter: UInt64, utc: UInt64? = nil) {
    guard frequency != 0 else { return nil }
    self.frequency = frequency
    origin = counter
    activeTicks = 0
    slept = 0
    suspended = false
    utcBoot = 0
    utcBase = utc
    correction = 0
  }

  func budget(at boot: UInt64) -> (ordinary: UInt64, leap: UInt64) {
    smear?.budget(from: utcBoot, to: boot) ?? ((boot - utcBoot) / 2000, 0)
  }

  func wallTime(_ boot: UInt64) -> UInt64? {
    guard let base = utcBase, boot >= utcBoot else { return nil }
    let elapsed = boot - utcBoot
    let budget = budget(at: boot)
    let shift = min(correction.magnitude, budget.ordinary)
    let slow = (correction < 0 ? shift : 0) + (smear?.leap == .insertion ? budget.leap : 0)
    let fast = (correction > 0 ? shift : 0) + (smear?.leap == .deletion ? budget.leap : 0)
    // Across a reanchor the next shared credit may lie just 1 ns away.
    let (adjusted, overflow) = (elapsed - slow).addingReportingOverflow(fast)
    guard !overflow else { return nil }
    return adjusted <= .max - base ? base + adjusted : nil
  }

  public func read(counter: UInt64) -> SystemTime? {
    guard !suspended, counter >= origin else { return nil }
    guard counter - origin <= .max - activeTicks else { return nil }
    let duration = counterDuration(activeTicks + (counter - origin), frequency: frequency)
    guard duration.valid else { return nil }
    let mono = duration.ns
    guard slept <= .max - mono else { return nil }
    let boot = mono + slept
    return SystemTime(monotonic: mono, boot: boot, utc: wallTime(boot))
  }

  /// Called only at boot or after the Clock resource's administrative
  /// authorization check. A step cancels the current slew and leap window;
  /// the service must reconsider that window against the new UTC.
  public mutating func stepUTC(to utc: UInt64, counter: UInt64) -> Bool {
    guard let time = read(counter: counter), time.boot >= utcBoot else { return false }
    utcBase = utc
    utcBoot = time.boot
    correction = 0
    smear = nil
    return true
  }

  /// Replace the outstanding correction without a discontinuity. Reads
  /// interpolate at at most 500 ppm and stop slewing at the requested amount.
  public mutating func slewUTC(by ns: Int64, counter: UInt64) -> Bool {
    guard let time = read(counter: counter), let utc = time.utc else { return false }
    utcBase = utc
    utcBoot = time.boot
    correction = ns
    return true
  }

  /// Publish this transition before counters stop or lose synchronization.
  public mutating func suspend(counter: UInt64) -> Bool {
    guard let time = read(counter: counter), time.boot >= utcBoot else { return false }
    activeTicks += counter - origin
    suspended = true
    return true
  }

  /// The power backend supplies elapsed sleep from an independent clock and
  /// the new synchronized counter sample; the old counter need not survive.
  public mutating func resume(counter: UInt64, sleepNS: UInt64) -> Bool {
    let awake = counterDuration(activeTicks, frequency: frequency)
    guard suspended, awake.valid, sleepNS <= .max - slept, slept + sleepNS <= .max - awake.ns
    else { return false }
    slept += sleepNS
    origin = counter
    suspended = false
    return true
  }
}
