// Round up to parts per billion; never round a reservation down. Long
// division avoids overflowing even for nanosecond periods near UInt64.max.
public func reservationPpb(_ budget: UInt64, _ period: UInt64, _ deadline: UInt64) -> UInt64 {
  if budget == 0 || budget > deadline || deadline > period { return 0 }
  if budget == period { return 1_000_000_000 }
  var result: UInt64 = 0
  var remainder = budget
  for _ in 0..<9 {
    let add = remainder
    var carry: UInt64 = 0
    remainder = 0
    for _ in 0..<10 {
      if remainder >= period - add {
        remainder -= period - add
        carry += 1
      } else {
        remainder += add
      }
    }
    result = result * 10 + carry
  }
  if remainder != 0 { result += 1 }
  return result
}

// clusterCapacityPpb is the normalized available CPU capacity, i.e. 1e9
// per full core. The caller holds the cluster and job accounting locks.
public func canAdmit(
  _ request: UInt64, _ clusterUsed: UInt64, _ clusterCapacityPpb: UInt64,
  _ jobUsed: UInt64, _ jobLimit: UInt64, _ entitled: Bool
) -> Bool {
  if !entitled || request == 0 || request > 1_000_000_000 { return false }
  let limit = clusterCapacityPpb / 10 * 9 + clusterCapacityPpb % 10 * 9 / 10
  if clusterUsed > limit || jobUsed > jobLimit { return false }
  return request <= limit - clusterUsed && request <= jobLimit - jobUsed
}

public struct PeriodBudget {
  public internal(set) var release: UInt64
  public internal(set) var remaining: UInt64
  public let period: UInt64
  public let capacity: UInt64

  // Move the release anchor by complete periods, never by dispatch time.
  public mutating func replenish(_ now: UInt64) {
    if period == 0 || now < release { return }
    let elapsed = now - release
    if elapsed >= period {
      release = now - elapsed % period
      remaining = capacity
    }
  }

  // Accounting is against the scheduling context, including a donated one.
  // Split an interval at the next release before charging it here.
  public mutating func charge(_ runtime: UInt64) {
    if runtime >= remaining { remaining = 0 } else { remaining -= runtime }
  }

  public init(release: UInt64, remaining: UInt64, period: UInt64, capacity: UInt64) {
    self.release = release
    self.remaining = remaining
    self.period = period
    self.capacity = capacity
  }
}
