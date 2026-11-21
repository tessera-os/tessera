public enum TimerDomain {
  case monotonic, boot, utc

  func value(in time: SystemTime) -> UInt64? {
    switch self {
    case .monotonic: time.monotonic
    case .boot: time.boot
    case .utc: time.utc
    }
  }
}

public enum TimerTolerance {
  case strict, interactive, standard, background

  func limit(interval: UInt64) -> UInt64 {
    switch self {
    case .strict: 0
    case .interactive: 1_000_000
    case .standard: 5_000_000
    case .background: backgroundSlack(interval)
    }
  }
}

/// Kernel-private cancellation key, never a process handle. Use a fresh
/// nonzero queue identity on every initialization, including after teardown.
public struct TimerKey {
  fileprivate let owner, generation: UInt64
  fileprivate let index: Int
}

/// Backing for two indexed binary heaps over the same one-shot timers:
/// earliest deadline for delivery, earliest end of slack for programming.
public struct TimerSlot {
  fileprivate var deadline: UInt64 = 0, latest: UInt64 = 0, generation: UInt64 = 0, cookie: UInt64 = 0
  fileprivate var byStart = 0, byEnd = 0, startPosition = 0, endPosition = 0, next = -1
  public init() {}
}

/// One clock and wake class per queue. Keep the initialized backing pinned
/// and exclusive, with timer creation, cancellation, clock updates, IRQ
/// dispatch and hardware rearming serialized by the owning kernel context.
/// The process object owner enforces its aggregate quota across queues.
public struct OneShotTimers: ~Copyable {
  let domain: TimerDomain
  let wakesSystem: Bool
  private let owner: UInt64
  private let slots: UnsafeMutableBufferPointer<TimerSlot>
  private var nextGeneration: UInt64 = 1
  private var free = 0
  public private(set) var count = 0

  @unsafe public init?(
    storage: UnsafeMutableBufferPointer<TimerSlot>, identity: UInt64, domain: TimerDomain,
    wakesSystem: Bool
  ) {
    guard identity != 0, !storage.isEmpty, storage.count <= 65_536 else { return nil }
    slots = storage
    owner = identity
    self.domain = domain
    self.wakesSystem = wakesSystem
    for i in storage.indices {
      slots[i] = TimerSlot()
      slots[i].next = i + 1 == storage.count ? -1 : i + 1
    }
  }

  private func at(_ pos: Int, _ end: Bool) -> Int {
    end ? slots[pos].byEnd : slots[pos].byStart
  }

  private func place(_ index: Int, _ pos: Int, _ end: Bool) {
    if end { slots[pos].byEnd = index; slots[index].endPosition = pos }
    else { slots[pos].byStart = index; slots[index].startPosition = pos }
  }

  private func before(_ lhs: Int, _ rhs: Int, _ end: Bool) -> Bool {
    let a = end ? slots[lhs].latest : slots[lhs].deadline
    let b = end ? slots[rhs].latest : slots[rhs].deadline
    return a == b ? lhs < rhs : a < b
  }

  private func repair(_ index: Int, from: Int, size: Int, end: Bool) {
    var pos = from
    while pos > 0 {
      let parent = (pos - 1) / 2, other = at(parent, end)
      guard before(index, other, end) else { break }
      place(other, pos, end)
      pos = parent
    }
    while pos * 2 + 1 < size {
      var child = pos * 2 + 1
      if child + 1 < size && before(at(child + 1, end), at(child, end), end) { child += 1 }
      let other = at(child, end)
      guard before(other, index, end) else { break }
      place(other, pos, end)
      pos = child
    }
    place(index, pos, end)
  }

  /// Supply the kernel object's cookie, not an address from the caller.
  /// Explicit slack tightens the class cap. Unclassified hard deadlines use
  /// zero slack. A wall-clock timer cannot be armed before UTC is available.
  public mutating func arm(
    deadline: UInt64, at now: SystemTime, tolerance: TimerTolerance, slack: UInt64? = nil,
    cookie: UInt64
  ) -> TimerKey? {
    guard cookie != 0, free >= 0, nextGeneration != 0, let current = domain.value(in: now)
    else { return nil }
    let i = free
    free = slots[i].next
    slots[i].deadline = deadline
    slots[i].latest = Self.windowEnd(deadline, now: current, tolerance: tolerance, slack: slack)
    slots[i].cookie = cookie
    slots[i].generation = nextGeneration
    let key = TimerKey(owner: owner, generation: nextGeneration, index: i)
    nextGeneration &+= 1 // zero permanently closes this queue to new timers
    repair(i, from: count, size: count + 1, end: false)
    repair(i, from: count, size: count + 1, end: true)
    count += 1
    return key
  }

  private mutating func remove(_ i: Int) {
    count -= 1
    let first = slots[i].startPosition, last = slots[i].endPosition
    if first < count { repair(at(count, false), from: first, size: count, end: false) }
    if last < count { repair(at(count, true), from: last, size: count, end: true) }
    slots[i].generation = 0
    slots[i].cookie = 0
    slots[i].next = free
    free = i
  }

  /// Change an armed deadline without consuming another slot or invalidating
  /// its cancellation key. Failure leaves the old deadline intact.
  public mutating func rearm(
    _ key: TimerKey, deadline: UInt64, at now: SystemTime, tolerance: TimerTolerance,
    slack: UInt64? = nil
  ) -> Bool {
    guard owns(key), let current = domain.value(in: now) else { return false }
    let i = key.index
    slots[i].deadline = deadline
    slots[i].latest = Self.windowEnd(deadline, now: current, tolerance: tolerance, slack: slack)
    repair(i, from: slots[i].startPosition, size: count, end: false)
    repair(i, from: slots[i].endPosition, size: count, end: true)
    return true
  }

  private static func windowEnd(
    _ deadline: UInt64, now: UInt64, tolerance: TimerTolerance, slack: UInt64?
  ) -> UInt64 {
    let cap = tolerance.limit(interval: deadline > now ? deadline - now : 0)
    return deadline + min(min(slack ?? cap, cap), UInt64.max - deadline)
  }

  private func owns(_ key: TimerKey) -> Bool {
    key.owner == owner && slots.indices.contains(key.index) && slots[key.index].generation == key.generation
  }

  public mutating func cancel(_ key: TimerKey) -> Bool {
    guard owns(key) else { return false }
    remove(key.index)
    return true
  }

  /// Drain after resume or from an awake CPU only. Recheck the clock rather
  /// than delivering on an old comparator or an early/spurious wakeup.
  public mutating func takeDue(at now: SystemTime) -> UInt64? {
    guard count > 0, let current = domain.value(in: now) else { return nil }
    let i = at(0, false)
    guard current >= slots[i].deadline else { return nil }
    let cookie = slots[i].cookie
    remove(i)
    return cookie
  }

  /// Greedy interval coalescing: by the earliest closing window all timers
  /// whose windows intersect it can be delivered together, never earlier
  /// than their own deadlines. Any earlier unrelated IRQ may drain them too.
  var nextLimit: UInt64? { count == 0 ? nil : slots[at(0, true)].latest }
  func hasDue(at current: UInt64) -> Bool { count > 0 && current >= slots[at(0, false)].deadline }
}
