/// During a positive leap the smeared UTC clock loses one second over the
/// window; a negative leap gains one. The time service chooses the start.
public enum LeapSecond { case insertion, deletion }

struct LeapSmear {
  static let duration: UInt64 = 86_400_000_000_000
  let start: UInt64
  let leap: LeapSecond

  // Partition a single 500-ppm budget into nanosecond credits. Five out
  // of every 216 credits go to the smear during its 24-hour window. The
  // common phase prevents a slew and a smear spending the same credit.
  private func credits(_ boot: UInt64) -> UInt64 {
    boot / 2000 + (boot % 2000 >= start % 2000 ? 1 : 0)
  }

  private func smeared(_ boot: UInt64) -> UInt64 {
    guard boot > start else { return 0 }
    return (min(boot - start, Self.duration) / 2000) * 5 / 216
  }

  func budget(from anchor: UInt64, to boot: UInt64) -> (ordinary: UInt64, leap: UInt64) {
    let leap = smeared(boot) - smeared(anchor)
    var ordinary = credits(boot) - credits(anchor) - leap
    // Drop a partial ordinary credit on reanchor. Even when installing a
    // window changes phase, no ordinary adjustment is spent twice within
    // 2 us. Do not discard a smear credit; its phase never changes.
    let phase = (anchor % 2000 + 2000 - start % 2000) % 2000
    if phase != 0, boot - anchor >= 2000 - phase,
      smeared(anchor + (2000 - phase)) == smeared(anchor) { ordinary -= 1 }
    return (ordinary, leap)
  }
}

extension SystemClocks {
  /// Privileged time-service operation. An accepted future window is not
  /// replaced while pending or in progress. Preserve the outstanding slew
  /// and current UTC when changing the interpolation parameters.
  public mutating func scheduleLeap(_ leap: LeapSecond, startingAtBoot start: UInt64,
    counter: UInt64) -> Bool
  {
    guard let now = read(counter: counter), let utc = now.utc, start >= now.boot,
      start <= .max - LeapSmear.duration,
      smear.map({ now.boot >= $0.start + LeapSmear.duration }) ?? true else { return false }
    let available = budget(at: now.boot).ordinary
    let remaining = correction.magnitude - min(correction.magnitude, available)
    correction = correction < 0 ? Int64(bitPattern: 0 &- remaining) : Int64(remaining)
    utcBoot = now.boot
    utcBase = utc
    smear = LeapSmear(start: start, leap: leap)
    return true
  }
}
