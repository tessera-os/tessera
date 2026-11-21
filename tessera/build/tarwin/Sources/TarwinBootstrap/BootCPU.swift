import TarwinSched
import TarwinTime

/// Only the boot CPU may own this queue, with interrupts masked until the
/// timer decision is applied and the architecture context switch is committed.
public struct BootCPU: ~Copyable {
  private var queue = BootstrapCPU(now: 0)
  private var origin: UInt64 = 0
  private var frequency: UInt64 = 0
  private var last: UInt64 = 0

  /// Initialize in per-CPU storage, not in an architecture entry frame.
  public init() {}

  /// Context 0 is the architecture idle context. All nonzero IDs must already
  /// have an initialized, kernel-owned context before being made runnable.
  public mutating func start(counter: UInt64, frequency: UInt64, initialContext: UInt64) -> Bool {
    guard self.frequency == 0, frequency != 0,
      queue.create(id: initialContext, qos: SchedClass.normal)
    else { return false }
    guard queue.wake(initialContext, now: 0) else {
      _ = queue.remove(initialContext, now: 0)
      return false
    }
    origin = counter
    last = counter
    self.frequency = frequency
    return true
  }

  public enum Event {
    case poll, yield, sleepRunning
    case add(context: UInt64, qos: UInt8)
    case wake(context: UInt64)
    case retire(context: UInt64)
  }

  public struct Dispatch {
    /// Counter sampled for this successful scheduler decision.
    public let counter: UInt64
    public let previous: UInt64
    public let next: UInt64
    /// Absolute hardware counter value, or nil to disarm the local slice timer.
    public let sliceCounter: UInt64?

    /// Apply the scheduler and timer-object decision to the same local
    /// comparator. Call with local interrupts masked in the original clock
    /// domain. Refusal is not permission to enter idle or commit a switch.
    public func programDeadline(
      timers: TimerWakePlan, clock: SystemClocks, counter: UInt64, set: (UInt64?) -> Bool
    ) -> Bool {
      switch timers {
      case .unavailable: return false
      case .none: return set(sliceCounter)
      case .atBoot(let limit):
        guard let timer = clock.compareValue(forBoot: limit, counter: counter) else { return false }
        if let sliceCounter { return set(min(sliceCounter, timer)) }
        return set(timer)
      }
    }
  }

  /// The caller supplies a sample of the same non-wrapping counter each time.
  /// A rejected event does not authorize an architecture switch.
  public mutating func service(_ event: Event, counter: UInt64) -> Dispatch? {
    guard frequency != 0, counter >= last else { return nil }
    let t = counterDuration(counter - origin, frequency: frequency)
    guard t.valid else { return nil }
    let now = t.ns
    let previous = queue.running
    var yield = false
    switch event {
    case .poll: break
    case .yield: yield = true
    case .sleepRunning: guard queue.sleepRunning(now: now) else { return nil }
    case .wake(let id): guard queue.wake(id, now: now) else { return nil }
    case .retire(let id): guard queue.remove(id, now: now) else { return nil }
    case .add(let id, let qos):
      guard queue.create(id: id, qos: qos) else { return nil }
      // Freshly created, suspended and on the owner CPU at a validated timestamp.
      guard queue.wake(id, now: now) else {
        _ = queue.remove(id, now: now)
        return nil
      }
    }
    last = counter
    let next = queue.select(now: now, yield: yield)
    var deadline: UInt64?
    if let end = queue.nextSliceEnd(now: now) {
      deadline = Self.counterAt(end, frequency: frequency, origin: origin)
    }
    return Dispatch(counter: counter, previous: previous, next: next, sliceCounter: deadline)
  }

  // ceil(ns * Hz / 10^9), split into seconds and a bounded fractional
  // product. If the counter cannot span the next slice, interrupt at its
  // last representable tick: never turn an armed slice into tickless idle.
  private static func counterAt(_ ns: UInt64, frequency: UInt64, origin: UInt64) -> UInt64 {
    guard let distance = deadlineTicks(ns, frequency: frequency), distance <= .max - origin
    else { return .max }
    return origin + distance
  }
}
