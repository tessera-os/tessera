/// Single-CPU queue for early kernel threads before the SMP scheduler is
/// online. The boot CPU owns all mutations with interrupts masked. Returns
/// a thread ID for the architecture switch; zero selects the idle context.
public struct BootstrapCPU: ~Copyable {
  private enum State { case free, suspended, ready, running, sleeping }
  private struct Slot {
    var id: UInt64 = 0
    var state: State = .free
    var qos: UInt8 = 0
    var weight: UInt64 = 17
    var slice: UInt64 = 3_000_000
    var served: UInt64 = 0
    var readyAt: UInt64 = 0
    var virtualStart: UInt64 = 0
    var virtualDeadline: UInt64 = 0
  }
  private var slots = InlineArray<64, Slot>(repeating: Slot())
  private var clocks = InlineArray<6, UInt64>(repeating: 0)
  private var weights = InlineArray<6, UInt64>(repeating: 0)
  private var active: Int? = nil
  private var starvationQuantum = false
  private var last: UInt64

  public init(now: UInt64) { last = now }
  // Mutating reads let Embedded Swift borrow individual inline slots in place.
  public var running: UInt64 {
    mutating get {
      if let i = active { return slots[i].id }
      return 0
    }
  }

  private mutating func find(_ id: UInt64) -> Int? {
    guard id != 0 else { return nil }
    for i in slots.indices where slots[i].id == id { return i }
    return nil
  }

  /// Deadline admission and donation are not available before SMP startup.
  public mutating func create(id: UInt64, qos: UInt8, priority: Int = 0, slice: UInt64 = 3_000_000)
    -> Bool
  {
    guard id != 0, find(id) == nil, (SchedClass.background...SchedClass.interactive).contains(qos),
      virtualSlice(slice, priority) != 0
    else { return false }
    for i in slots.indices where slots[i].state == .free {
      slots[i] = Slot(
        id: id, state: .suspended, qos: qos, weight: UInt64(priority + 17), slice: slice)
      return true
    }
    return false
  }

  private static func sum(_ a: UInt64, _ b: UInt64) -> UInt64 {
    let (v, overflow) = a.addingReportingOverflow(b)
    return overflow ? .max : v
  }

  // Compute floor(17 * runtime / weight) without overflowing at long uptimes.
  private static func scaled(_ runtime: UInt64, _ weight: UInt64) -> UInt64 {
    let (whole, overflow) = (runtime / weight).multipliedReportingOverflow(by: 17)
    return overflow ? .max : sum(whole, runtime % weight * 17 / weight)
  }

  private mutating func account(_ now: UInt64) -> Bool {
    guard now >= last else { return false }
    defer { last = now }
    guard let i = active else { return true }
    let elapsed = now - last
    let q = Int(slots[i].qos)
    clocks[q] = Self.sum(clocks[q], Self.scaled(elapsed, weights[q]))
    slots[i].served = Self.sum(slots[i].served, elapsed)
    return true
  }

  private mutating func request(_ i: Int, _ start: UInt64) {
    slots[i].virtualStart = start
    slots[i].virtualDeadline = Self.sum(
      start, virtualSlice(slots[i].slice, Int(slots[i].weight) - 17))
    slots[i].served = 0
  }

  public mutating func wake(_ id: UInt64, now: UInt64) -> Bool {
    guard let i = find(id), slots[i].state == .suspended || slots[i].state == .sleeping,
      account(now)
    else { return false }
    let q = Int(slots[i].qos)
    request(i, max(clocks[q], slots[i].virtualStart))
    slots[i].state = .ready
    slots[i].readyAt = now
    weights[q] += slots[i].weight
    return true
  }

  private mutating func deschedule(_ i: Int, now: UInt64) {
    let service = Self.scaled(slots[i].served, slots[i].weight)
    request(i, Self.sum(slots[i].virtualStart, service))
    slots[i].readyAt = now
    active = nil
    starvationQuantum = false
  }

  public mutating func sleepRunning(now: UInt64) -> Bool {
    guard let i = active, account(now) else { return false }
    weights[Int(slots[i].qos)] -= slots[i].weight
    deschedule(i, now: now)
    slots[i].state = .sleeping
    return true
  }

  public mutating func remove(_ id: UInt64, now: UInt64) -> Bool {
    guard let i = find(id), account(now) else { return false }
    if slots[i].state == .ready || slots[i].state == .running {
      weights[Int(slots[i].qos)] -= slots[i].weight
    }
    if active == i {
      active = nil
      starvationQuantum = false
    }
    slots[i] = Slot()
    return true
  }

  private mutating func key(_ i: Int) -> DispatchKey {
    let s = slots[i]
    return DispatchKey(
      qos: s.qos, readySince: s.readyAt, virtualStart: s.virtualStart,
      virtualDeadline: s.virtualDeadline, classVirtualTime: clocks[Int(s.qos)],
      absoluteDeadline: 0, remainingBudget: 0, threadId: s.id)
  }

  /// Call on wake, block, yield or timer expiry; a preemption before the
  /// end of a request preserves the outstanding virtual deadline.
  public mutating func select(now: UInt64, yield: Bool = false) -> UInt64 {
    guard account(now) else { return running }
    if let i = active {
      if yield || slots[i].served >= slots[i].slice {
        deschedule(i, now: now)
      } else {
        if starvationQuantum { return slots[i].id }
        slots[i].readyAt = now
      }
      slots[i].state = .ready
    }
    var next: Int?
    for i in slots.indices where slots[i].state == .ready {
      if let old = next, !dispatchBefore(key(i), key(old), now) { continue }
      next = i
    }
    active = next
    guard let i = next else { return 0 }
    starvationQuantum = key(i).starvationWait(now) > 0
    let q = Int(slots[i].qos)
    clocks[q] = max(clocks[q], slots[i].virtualStart)
    slots[i].state = .running
    return slots[i].id
  }

  /// A lone runnable thread is tickless. Additional wakes trigger select.
  public mutating func nextSliceEnd(now: UInt64) -> UInt64? {
    guard let i = active else { return nil }
    for j in slots.indices where slots[j].state == .ready {
      let since = now >= last ? now - last : 0
      let served = Self.sum(slots[i].served, since)
      return Self.sum(now, slots[i].slice - min(slots[i].slice, served))
    }
    return nil
  }
}
