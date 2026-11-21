/// One periodic work group, serialized by its kernel object lock. Members
/// are kernel thread IDs; the caller checks handle rights and job policy
/// before changing membership or declaring an interval. Times are monotonic.
public struct WorkInterval: ~Copyable {
  private let members: UnsafeMutableBufferPointer<UInt64>
  private let owner: UInt64
  public let referenceCapacity: UInt32
  private var generation: UInt64 = 0
  private var start: UInt64 = 0
  private var end: UInt64 = 0
  private var lastEnd: UInt64 = 0
  private var work: UInt64 = 0
  private var fractionalWork: UInt64 = 0
  private var estimate: UInt64?
  private var active = false

  /// Storage is initialized and exclusively owned throughout the object's
  /// lifetime. Capacity is in the same units as CpuOffer.capacity.
  public init?(
    owner: UInt64, referenceCapacity: UInt32, members: UnsafeMutableBufferPointer<UInt64>
  ) {
    guard owner != 0, referenceCapacity != 0, !members.isEmpty else { return nil }
    self.owner = owner
    self.referenceCapacity = referenceCapacity
    self.members = members
    for i in members.indices { members[i] = 0 }
  }

  private func slot(_ id: UInt64) -> Int? {
    for i in members.indices where members[i] == id { return i }
    return nil
  }

  public mutating func join(_ thread: UInt64, by caller: UInt64) -> Bool {
    guard caller == owner, thread != 0, slot(thread) == nil, let i = slot(0)
    else { return false }
    members[i] = thread
    return true
  }

  /// Also used during thread teardown, after removing it from the CPU.
  public mutating func leave(_ thread: UInt64) -> Bool {
    guard thread != 0, let i = slot(thread) else { return false }
    members[i] = 0
    return true
  }

  public mutating func begin(by caller: UInt64, start: UInt64, deadline: UInt64) -> UInt64? {
    guard caller == owner, !active, start >= lastEnd, deadline > start, generation < .max else {
      return nil
    }
    generation += 1
    self.start = start
    end = deadline
    work = 0
    fractionalWork = 0
    active = true
    return generation
  }

  /// Charge each scheduler accounting slice once to its interval at its
  /// CPU's actual capacity. A slice straddling an epoch is split by the
  /// caller. Accumulate in reference-CPU time units (rounded down).
  public mutating func charge(
    _ thread: UInt64, epoch: UInt64, from: UInt64, to: UInt64,
    capacity: UInt32
  ) -> Bool {
    guard active, epoch == generation, thread != 0, slot(thread) != nil,
      from >= start, to >= from, capacity > 0, capacity <= referenceCapacity
    else { return false }
    let ticks = to - from
    let ref = UInt64(referenceCapacity)
    let c = UInt64(capacity)
    let fraction = ticks % ref * c + fractionalWork
    fractionalWork = fraction % ref
    let n = ticks / ref * c + fraction / ref
    let (sum, overflow) = work.addingReportingOverflow(n)
    work = overflow ? .max : sum
    lastEnd = max(lastEnd, to)
    return true
  }

  public mutating func complete(by caller: UInt64, epoch: UInt64, now: UInt64) -> Bool {
    guard active, caller == owner, epoch == generation, now >= start, now >= lastEnd else {
      return false
    }
    if let old = estimate {
      // EWMA with weight 1/4; bias upwards by at most one time unit.
      if work >= old {
        let delta = work - old
        estimate = old + delta / 4 + (delta % 4 != 0 ? 1 : 0)
      } else {
        estimate = old - (old - work) / 4
      }
    } else {
      estimate = work
    }
    active = false
    lastEnd = now
    return true
  }

  /// Additional demand for this runnable member, not a deadline-class
  /// reservation. It never overrides ISA, SMT, thermal or job limits.
  public func demand(_ thread: UInt64, now: UInt64) -> UInt32 {
    guard active, thread != 0, slot(thread) != nil, now >= start else { return 0 }
    guard now < end else { return referenceCapacity }
    guard let estimate, estimate != 0 else { return 0 }
    guard estimate > work else { return referenceCapacity }
    let left = estimate - work
    let window = end - now
    guard left < window else { return referenceCapacity }
    let fraction = reservationPpb(left, window, window)
    return UInt32((fraction * UInt64(referenceCapacity) + 999_999_999) / 1_000_000_000)
  }
}
