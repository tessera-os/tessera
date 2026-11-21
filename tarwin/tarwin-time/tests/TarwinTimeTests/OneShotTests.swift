import TarwinTime
import Testing

private func withTimers(
  _ domain: TimerDomain, wake: Bool = false, count: Int = 8, id: UInt64 = 1,
  _ body: (inout OneShotTimers) throws -> Void
) throws {
  var slots = Array(repeating: TimerSlot(), count: count)
  try slots.withUnsafeMutableBufferPointer {
    guard var queue = OneShotTimers(storage: $0, identity: id, domain: domain, wakesSystem: wake)
    else { Issue.record("queue refused"); return }
    try body(&queue)
  }
}

@Test func indexedTimersStayOrderedAcrossCancelAndSlotReuse() throws {
  let clock = try #require(SystemClocks(frequency: 1_000_000_000, counter: 0))
  let origin = try #require(clock.read(counter: 0))
  try withTimers(.boot, count: 127) { queue in
    var seed: UInt64 = 71, cookie: UInt64 = 0
    func draw() -> UInt64 {
      seed = seed &* 6364136223846793005 &+ 1442695040888963407
      return seed >> 32
    }
    var pending: [UInt64: (key: TimerKey, start: UInt64, end: UInt64)] = [:]
    var stale: TimerKey?
    for now in UInt64(0)..<3000 {
      if now % 3 == 0, let i = pending.keys.sorted().first, let item = pending.removeValue(forKey: i) {
        #expect(queue.cancel(item.key) == true)
        stale = item.key
      }
      for _ in 0..<2 {
        let start = now + draw() % 100, slack = draw() % 23
        cookie += 1
        if let key = queue.arm(deadline: start, at: origin, tolerance: .standard, slack: slack, cookie: cookie) {
          pending[cookie] = (key, start, start + slack)
        } else { #expect(pending.count == 127) }
      }
      if let stale { #expect(queue.cancel(stale) == false) }
      if now % 7 == 0, let i = pending.keys.max(), let item = pending[i] {
        let start = now + draw() % 120, slack = draw() % 19
        #expect(queue.rearm(item.key, deadline: start, at: origin, tolerance: .interactive, slack: slack) == true)
        pending[i] = (item.key, start, start + slack)
      }
      let expected = pending.values.map(\.end).min().map { TimerWakePlan.atBoot(max(now,$0)) } ?? .none
      #expect(queue.nextWake(clock: clock, counter: now, preparingSleep: false) == expected)
      if now % 17 == 0 {
        let time = try #require(clock.read(counter: now))
        while let item = queue.takeDue(at: time) {
          let removed = pending.removeValue(forKey: item)
          let fired = try #require(removed)
          #expect(fired.start <= now)
        }
        #expect(pending.values.allSatisfy { $0.start > now })
      }
      #expect(queue.count == pending.count)
    }
  }
}

@Test func timerCapacityAndQoS() throws {
  let clock = try #require(SystemClocks(frequency: 1_000_000_000, counter: 0))
  let now = try #require(clock.read(counter: 0))
  try withTimers(.boot, count: 65536) { queue in
    for i in 1...65536 {
      guard queue.arm(deadline: UInt64(i), at: now, tolerance: .strict, cookie: UInt64(i)) != nil
      else { Issue.record("refused within capacity"); return }
    }
    let full = queue.arm(deadline: 100, at: now, tolerance: .strict, cookie: 65537)
    #expect(full == nil && queue.count == 65536)
  }
  try withTimers(.monotonic, wake: true, count: 1) { queue in
    for (q,limit) in [(TimerTolerance.interactive, UInt64(1_000_000)), (.standard,5_000_000),
      (.background,1_000_000_000), (.strict,0)] {
      let start: UInt64 = 12_000_000_000
      let armed = queue.arm(deadline: start, at: now, tolerance: q, slack: .max, cookie: 3)
      let key = try #require(armed)
      #expect(queue.nextWake(clock: clock, counter: 0, preparingSleep: false) == .atBoot(start + limit))
      #expect(queue.nextWake(clock: clock, counter: 0, preparingSleep: true) == .unavailable)
      #expect(queue.nextWake(clock: clock, counter: start, preparingSleep: true) == .atBoot(start))
      try withTimers(.boot, id: 2) { other in
        _ = other.arm(deadline: 1, at: now, tolerance: .strict, cookie: 3)
        #expect(other.cancel(key) == false)
      }
      #expect(queue.cancel(key) == true)
    }
    _ = queue.arm(deadline: .max - 1, at: now, tolerance: .background, cookie: 7)
    #expect(queue.nextWake(clock: clock, counter: 0, preparingSleep: false) == .atBoot(.max))
  }
}

@Test func differentClockDomainsAcrossSleep() throws {
  var clock = try #require(SystemClocks(frequency: 1_000_000_000, counter: 3))
  let now = try #require(clock.read(counter: 3))
  try withTimers(.boot, wake: true) { wake in
    try withTimers(.boot) { deferred in
      try withTimers(.monotonic) { active in
        _ = wake.arm(deadline: 100, at: now, tolerance: .strict, cookie: 71)
        _ = deferred.arm(deadline: 50, at: now, tolerance: .strict, cookie: 72)
        _ = active.arm(deadline: 80, at: now, tolerance: .strict, cookie: 73)
        #expect(deferred.nextWake(clock: clock, counter: 3, preparingSleep: true) == .none)
        #expect(wake.nextWake(clock: clock, counter: 3, preparingSleep: true) == .atBoot(100))
        #expect(clock.suspend(counter: 13) == true)
        #expect(clock.resume(counter: 0, sleepNS: 95) == true)
        let resumed = try #require(clock.read(counter: 0))
        #expect(wake.takeDue(at: resumed) == 71 && deferred.takeDue(at: resumed) == 72)
        #expect(active.takeDue(at: resumed) == nil)
        #expect(active.nextWake(clock: clock, counter: 0, preparingSleep: false) == .atBoot(175))
        #expect(clock.compareValue(forBoot: 175, counter: 0) == 70)
      }
    }
  }
}

@Test func timerWakeRecalculatesAfterUtcSlewAndStep() throws {
  var clock = try #require(SystemClocks(frequency: 1_000_000_000, counter: 0))
  try withTimers(.utc, wake: true) { queue in
    let unsynced = try #require(clock.read(counter: 0))
    let key = queue.arm(deadline: 1, at: unsynced, tolerance: .strict, cookie: 99)
    #expect(key == nil)
    #expect(clock.stepUTC(to: 1_000, counter: 0) == true)
    let t = try #require(clock.read(counter: 0))
    _ = queue.arm(deadline: 21_000, at: t, tolerance: .strict, cookie: 99)
    for (shift, target) in [(Int64(80), UInt64(19_991)), (-80,20_010), (1,19_999)] {
      #expect(clock.slewUTC(by: shift, counter: 0) == true)
      #expect(queue.nextWake(clock: clock, counter: 0, preparingSleep: true) == .atBoot(target))
      let early = try #require(clock.read(counter: target - 1))
      #expect(queue.takeDue(at: early) == nil)
    }
    #expect(clock.stepUTC(to: 22_000, counter: 110) == true)
    #expect(queue.nextWake(clock: clock, counter: 110, preparingSleep: true) == .atBoot(110))
    let stepped = try #require(clock.read(counter: 110))
    #expect(queue.takeDue(at: stepped) == 99)
    #expect(queue.takeDue(at: stepped) == nil)
  }
}
