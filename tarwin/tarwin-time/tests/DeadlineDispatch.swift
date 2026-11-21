import TarwinBootstrap
import TarwinTime

/// Exercise the real boot CPU queue and timer comparator. Only the decision
/// is made here; these diagnostic contexts do not own running thread stacks.
func checkSlice(
  frequency: UInt64, counter: () -> UInt64, set: (UInt64?) -> Bool,
  wait: () -> Void, stopped: () -> Bool
) -> Bool {
  var cpu = BootCPU()
  let origin = counter()
  guard cpu.start(counter: origin, frequency: frequency, initialContext: 1),
    let first = cpu.service(.poll, counter: origin), first.next == 1,
    first.sliceCounter == nil, set(first.sliceCounter), stopped(),
    let pair = cpu.service(.add(context: 2, qos: 3), counter: counter()), pair.next == 1,
    let target = pair.sliceCounter, set(target) else { return false }
  wait()
  let delivered = counter()
  guard delivered >= target, let decision = cpu.service(.poll, counter: delivered),
    decision.previous == 1, decision.next == 2,
    let only = cpu.service(.sleepRunning, counter: counter()), only.next == 1,
    only.sliceCounter == nil, set(only.sliceCounter), stopped(),
    let idle = cpu.service(.retire(context: 1), counter: counter()), idle.next == 0,
    idle.sliceCounter == nil, set(idle.sliceCounter), stopped() else { return false }
  return true
}

func checkCoalescedIRQ(
  clock: SystemClocks, frequency: UInt64, counter: () -> UInt64, set: (UInt64?) -> Bool,
  wait: () -> Void, stopped: () -> Bool
) -> Bool {
  var storage = InlineArray<3, TimerSlot>(repeating: TimerSlot())
  return withUnsafeMutableBytes(of: &storage) {
    let sample = counter()
    var cpu = BootCPU()
    guard cpu.start(counter: sample, frequency: frequency, initialContext: 1),
      cpu.service(.poll, counter: sample)?.next == 1,
      let idle = cpu.service(.sleepRunning, counter: sample),
      idle.next == 0, idle.sliceCounter == nil,
      let now = clock.read(counter: sample),
      var timers = OneShotTimers(storage: $0.bindMemory(to: TimerSlot.self), identity: 1,
        domain: .boot, wakesSystem: false)
    else { return false }
    let first = now.boot + 8_000_000, second = first + 1_000_000
    guard timers.arm(deadline: first, at: now, tolerance: .interactive, cookie: 1) != nil,
      timers.arm(deadline: second, at: now, tolerance: .strict, cookie: 2) != nil,
      let cancelled = timers.arm(deadline: first - 1000, at: now, tolerance: .strict, cookie: 3),
      timers.cancel(cancelled), !timers.cancel(cancelled),
      timers.takeDue(at: now) == nil,
      timers.nextWake(clock: clock, counter: sample, preparingSleep: true) == .none,
      case .atBoot(let limit) = timers.nextWake(clock: clock, counter: sample, preparingSleep: false),
      limit == second, idle.programDeadline(timers: .atBoot(limit), clock: clock, counter: sample, set: set)
    else { return false }
    wait()
    let current = counter()
    guard let delivered = clock.read(counter: current), delivered.boot >= second,
      let cookie = timers.takeDue(at: delivered), cookie == 1,
      let resumed = cpu.service(.wake(context: cookie), counter: current), resumed.next == 1,
      timers.takeDue(at: delivered) == 2,
      timers.takeDue(at: delivered) == nil, timers.count == 0,
      timers.nextWake(clock: clock, counter: counter(), preparingSleep: false) == .none
    else { return false }
    return resumed.programDeadline(timers: .none, clock: clock, counter: current, set: set) && stopped()
  }
}
