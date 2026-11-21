/// Single-CPU queue for early kernel threads before the SMP scheduler is
/// online. The boot CPU owns all mutations with interrupts masked. Returns
/// a thread ID for the architecture switch; zero selects the idle context.
public struct BootstrapCPU: ~Copyable {
  private enum State { case free, suspended, ready, running, sleeping, receiving, serving }
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
    var receiveEpoch: UInt64 = 0
    var executor: UInt8 = .max
  }
  private var slots = InlineArray<64, Slot>(repeating: Slot())
  private var clocks = InlineArray<6, UInt64>(repeating: 0)
  private var weights = InlineArray<6, UInt64>(repeating: 0)
  private var active: Int? = nil
  private var starvationQuantum = false
  private var last: UInt64
  private let identity: UInt64
  private var receiveEpoch: UInt64 = 0

  /// Supply the stable, unique nonzero CPU identity for direct service calls.
  public init(now: UInt64, identity: UInt64 = 0) {
    self.identity = identity
    last = now
  }
  // Mutating reads let Embedded Swift borrow individual inline slots in place.
  public var running: UInt64 {
    mutating get {
      guard let i = active else { return 0 }
      let executor = slots[i].executor
      return slots[executor == .max ? i : Int(executor)].id
    }
  }
  public var charging: UInt64 {
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

  /// Deadline admission is not available before SMP startup.
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
    makeReady(i, now: now)
    return true
  }

  private mutating func makeReady(_ i: Int, now: UInt64) {
    let q = Int(slots[i].qos)
    request(i, max(clocks[q], slots[i].virtualStart))
    slots[i].state = .ready
    slots[i].readyAt = now
    weights[q] += slots[i].weight
  }

  private mutating func deschedule(_ i: Int, now: UInt64) {
    let service = Self.scaled(slots[i].served, slots[i].weight)
    request(i, Self.sum(slots[i].virtualStart, service))
    slots[i].readyAt = now
    active = nil
    starvationQuantum = false
  }

  public mutating func sleepRunning(now: UInt64) -> Bool {
    guard let i = active, slots[i].executor == .max, account(now) else { return false }
    weights[Int(slots[i].qos)] -= slots[i].weight
    deschedule(i, now: now)
    slots[i].state = .sleeping
    return true
  }

  public mutating func remove(_ id: UInt64, now: UInt64) -> Bool {
    guard let i = find(id), slots[i].executor == .max, slots[i].state != .serving, account(now)
    else { return false }
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
        if starvationQuantum { return running }
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
    return running
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

extension BootstrapCPU {
  /// Opaque single-receive token. Service and thread KOIDs are kernel-owned.
  public struct Receiver {
    public let service, thread: UInt64
    fileprivate let cpu, epoch: UInt64
    fileprivate let slot: Int
  }

  public struct Donation {
    public let receiver: Receiver
    public let caller: UInt64
    fileprivate let source: Int
  }

  public mutating func waitForService(_ service: UInt64, now: UInt64) -> Receiver? {
    guard identity != 0, service != 0, receiveEpoch != .max, let i = active,
      sleepRunning(now: now)
    else { return nil }
    receiveEpoch += 1
    slots[i].receiveEpoch = receiveEpoch
    slots[i].state = .receiving
    return Receiver(
      service: service, thread: slots[i].id, cpu: identity,
      epoch: receiveEpoch, slot: i)
  }

  private mutating func matches(_ wait: Receiver, _ state: State) -> Bool {
    wait.cpu == identity && slots[wait.slot].id == wait.thread
      && slots[wait.slot].state == state && slots[wait.slot].receiveEpoch == wait.epoch
  }

  public mutating func withdraw(_ wait: Receiver, now: UInt64) -> Bool {
    guard matches(wait, .receiving), account(now) else { return false }
    makeReady(wait.slot, now: now)
    return true
  }

  /// The IPC owner holds the service and task locks and masks local interrupts
  /// through the switch. Deliver only to the preflighted, pinned receiver.
  /// On false, delivery must have published nothing. No run queue scan or
  /// reweighting: the caller's existing scheduling slot now executes the server.
  public mutating func call(
    _ service: UInt64, waiting: Receiver, now: UInt64,
    deliver: () -> Bool
  ) -> Donation? {
    guard let i = active, slots[i].executor == .max, service == waiting.service,
      matches(waiting, .receiving), account(now), deliver()
    else { return nil }
    slots[i].executor = UInt8(waiting.slot)
    slots[waiting.slot].state = .serving
    return Donation(receiver: waiting, caller: slots[i].id, source: i)
  }

  private mutating func outstanding(_ loan: Donation) -> Bool {
    matches(loan.receiver, .serving) && slots[loan.source].id == loan.caller
      && slots[loan.source].executor == UInt8(loan.receiver.slot)
  }

  private mutating func restore(_ loan: Donation, now: UInt64) {
    slots[loan.source].executor = .max
    makeReady(loan.receiver.slot, now: now)
  }

  public mutating func reply(_ loan: Donation, now: UInt64, deliver: () -> Bool) -> Bool {
    guard active == loan.source, outstanding(loan), account(now), deliver() else { return false }
    restore(loan, now: now)
    return true
  }

  /// Return the loan even if preempted. If active, switch from the worker to
  /// the caller before unmasking interrupts; a late reply cannot deliver data.
  public mutating func revoke(_ loan: Donation, now: UInt64) -> Bool {
    guard outstanding(loan), account(now) else { return false }
    restore(loan, now: now)
    return true
  }
}
