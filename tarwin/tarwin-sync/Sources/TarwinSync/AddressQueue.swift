import Synchronization

public struct AddressBucket: ~Copyable {
  fileprivate let locked = Atomic<Bool>(false)
  fileprivate var first = -1, last = -1
  public init() {}

  fileprivate borrowing func acquire() {
    while true {
      if !locked.load(ordering: .relaxed),
        locked.compareExchange(expected: false, desired: true, ordering: .acquiring).exchanged
      {
        return
      }
    }
  }
  fileprivate borrowing func release() { locked.store(false, ordering: .releasing) }
}

/// One slot owned by the scheduler for each thread. Its number stays valid
/// until all callbacks and timers have gone; do not reset it on thread reuse.
public struct AddressSleeper: ~Copyable {
  fileprivate let bucket = Atomic<Int>(-1)
  fileprivate var serial: UInt64 = 0
  fileprivate var key = WaitAddress(frame: 0, offset: 0)
  fileprivate var owner: UInt64 = 0
  fileprivate var prev = -1, next = -1
  public init() {}
}

public struct SleepTicket: Equatable, Sendable {
  public let slot: Int
  fileprivate let serial: UInt64
}

public enum WaitEnd { case woken, timeout, cancelled }
public enum ArmResult {
  case blocked(SleepTicket)
  case invalidArgument, badState, timeout, fault
}
public enum AddressChange {
  case block(SleepTicket, key: WaitAddress, owner: UInt64)
  case move(SleepTicket, from: WaitAddress, to: WaitAddress, oldOwner: UInt64, newOwner: UInt64)
  case ready(SleepTicket, from: WaitAddress, owner: UInt64, reason: WaitEnd)
}

/// Physical frame/offset wait queues. The two disjoint, initialized slabs must
/// outlive this table and all users and must be exclusively managed through it.
/// Disable preemption and prevent same-CPU interrupt re-entry on every path,
/// including timeout. Tickets are local to this table. Load only pinned memory;
/// change callbacks take/drop backing pins and mark scheduler states (including
/// donation) without sleeping, faulting or re-entering. Switch only after return
/// and only if the ticket remains blocked: a concurrent wake may already win.
public struct AddressQueue: ~Copyable {
  private let buckets: UnsafeMutableBufferPointer<AddressBucket>
  private let sleepers: UnsafeMutableBufferPointer<AddressSleeper>
  private let pageBytes: UInt32
  public init?(
    buckets: UnsafeMutableBufferPointer<AddressBucket>,
    sleepers: UnsafeMutableBufferPointer<AddressSleeper>, pageBytes: UInt32
  ) {
    guard !buckets.isEmpty, !sleepers.isEmpty, pageBytes == 4096 || pageBytes == 16384 else {
      return nil
    }
    self.buckets = buckets
    self.sleepers = sleepers
    self.pageBytes = pageBytes
  }

  private func bucket(_ key: WaitAddress) -> Int { Int(key.bucketHash() % UInt64(buckets.count)) }
  private func append(_ i: Int, _ b: Int) {
    let prev = buckets[b].last
    sleepers[i].prev = prev
    sleepers[i].next = -1
    if prev == -1 { buckets[b].first = i } else { sleepers[prev].next = i }
    buckets[b].last = i
  }
  private func unlink(_ i: Int, _ b: Int) {
    let prev = sleepers[i].prev
    let next = sleepers[i].next
    if prev == -1 { buckets[b].first = next } else { sleepers[prev].next = next }
    if next == -1 { buckets[b].last = prev } else { sleepers[next].prev = prev }
    sleepers[i].prev = -1
    sleepers[i].next = -1
  }

  /// load and now are sampled after taking the key lock, never before.
  /// owner must come from a resolved PI mutex owner, not an unchecked user ID.
  public func arm(
    slot: Int, key: WaitAddress, width: UInt32, expected: UInt64,
    deadline: UInt64, owner: UInt64 = 0, load: () -> UInt64?,
    now: () -> UInt64, change: (AddressChange) -> Void
  ) -> ArmResult {
    guard sleepers.indices.contains(slot), key.valid(pageBytes, width),
      width == 8 || expected <= UInt64(UInt32.max),
      width == 4 || owner == 0
    else { return .invalidArgument }
    let b = bucket(key)
    buckets[b].acquire()
    defer { buckets[b].release() }
    guard let word = load() else { return .fault }
    guard word == expected else { return .badState }
    guard deadline == .max || now() < deadline else { return .timeout }
    guard
      sleepers[slot].bucket.compareExchange(
        expected: -1, desired: b,
        ordering: .acquiringAndReleasing
      ).exchanged
    else { return .badState }
    guard sleepers[slot].serial != .max else {
      sleepers[slot].bucket.store(-1, ordering: .releasing)
      return .badState
    }
    sleepers[slot].serial += 1
    let ticket = SleepTicket(slot: slot, serial: sleepers[slot].serial)
    sleepers[slot].key = key
    sleepers[slot].owner = owner
    append(slot, b)
    change(.block(ticket, key: key, owner: owner))
    return .blocked(ticket)
  }

  private func ready(_ slot: Int, _ b: Int, _ reason: WaitEnd, _ change: (AddressChange) -> Void) {
    let ticket = SleepTicket(slot: slot, serial: sleepers[slot].serial)
    unlink(slot, b)
    change(.ready(ticket, from: sleepers[slot].key, owner: sleepers[slot].owner, reason: reason))
    sleepers[slot].bucket.store(-1, ordering: .releasing)
  }

  /// A stale timeout can neither remove a successor nor lose a requeued waiter.
  public func finish(_ ticket: SleepTicket, reason: WaitEnd, change: (AddressChange) -> Void)
    -> Bool
  {
    guard sleepers.indices.contains(ticket.slot) else { return false }
    while true {
      let b = sleepers[ticket.slot].bucket.load(ordering: .acquiring)
      if b == -1 { return false }
      buckets[b].acquire()
      if sleepers[ticket.slot].bucket.load(ordering: .acquiring) != b {
        buckets[b].release()
        continue
      }
      defer { buckets[b].release() }
      guard sleepers[ticket.slot].serial == ticket.serial else { return false }
      ready(ticket.slot, b, reason, change)
      return true
    }
  }

  public func wake(_ key: WaitAddress, count: UInt32, change: (AddressChange) -> Void) -> UInt32? {
    guard key.valid(pageBytes, 4) else { return nil }
    let b = bucket(key)
    buckets[b].acquire()
    defer { buckets[b].release() }
    return wakeLocked(key, b, count, change)
  }

  private func wakeLocked(
    _ key: WaitAddress, _ b: Int, _ limit: UInt32, _ change: (AddressChange) -> Void
  ) -> UInt32 {
    var i = buckets[b].first
    var n: UInt32 = 0
    while i >= 0 && n < limit {
      let next = sleepers[i].next
      if sleepers[i].key.same(key) {
        ready(i, b, .woken, change)
        n += 1
      }
      i = next
    }
    return n
  }

  /// Source and target are keys, not word reads. Acquire distinct locks in
  /// bucket order even for opposing requeues. Preserve FIFO at the target.
  public func requeue(
    from: WaitAddress, wake: UInt32, to: WaitAddress, move: UInt32,
    newOwner: UInt64 = 0, change: (AddressChange) -> Void
  ) -> (woken: UInt32, moved: UInt32)? {
    guard from.valid(pageBytes, 4), to.valid(pageBytes, 4), !from.same(to) else { return nil }
    let a = bucket(from)
    let b = bucket(to)
    let lo = min(a, b)
    let hi = max(a, b)
    buckets[lo].acquire()
    if hi != lo { buckets[hi].acquire() }
    defer {
      if hi != lo { buckets[hi].release() }
      buckets[lo].release()
    }
    let woken = wakeLocked(from, a, wake, change)
    var i = buckets[a].first
    var moved: UInt32 = 0
    let last = buckets[a].last
    while i >= 0 && moved < move {
      let next = sleepers[i].next
      if sleepers[i].key.same(from) {
        let old = sleepers[i].owner
        unlink(i, a)
        append(i, b)
        sleepers[i].key = to
        sleepers[i].owner = newOwner
        sleepers[i].bucket.store(b, ordering: .releasing)
        change(
          .move(
            SleepTicket(slot: i, serial: sleepers[i].serial), from: from, to: to, oldOwner: old,
            newOwner: newOwner))
        moved += 1
      }
      if i == last { break }
      i = next
    }
    return (woken, moved)
  }
}
