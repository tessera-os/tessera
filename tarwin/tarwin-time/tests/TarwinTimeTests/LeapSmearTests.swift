import TarwinTime
import Testing

private let day: UInt64 = 86_400_000_000_000

@Test func spreadsBothLeapSignsAcrossBootTime() throws {
  for kind in [LeapSecond.insertion, .deletion] {
    var clock = try #require(SystemClocks(frequency: 1_000_000_000, counter: 0, utc: 42))
    let start: UInt64 = 27_003
    #expect(clock.scheduleLeap(kind, startingAtBoot: start, counter: 0) == true)
    #expect(clock.scheduleLeap(kind, startingAtBoot: start, counter: 1) == false)
    #expect(clock.read(counter: start - 1)?.utc == start + 41)
    for (dt, amount) in [(UInt64(0), UInt64(0)), (day / 2, 500_000_000),
      (day - 1, 999_999_999), (day, 1_000_000_000), (day + 12_345, 1_000_000_000)] {
      let normal = start + dt + 42
      #expect(clock.read(counter: start + dt)?.utc == (kind == .insertion ? normal - amount : normal + amount))
    }
    #expect(clock.suspend(counter: start) == true)
    #expect(clock.resume(counter: 5, sleepNS: day) == true)
    #expect(clock.read(counter: 5)?.monotonic == start)
    let newStart = start + day
    #expect(clock.scheduleLeap(kind, startingAtBoot: newStart, counter: 5) == true)
  }
}

@Test func simultaneousCorrectionsShareOneRateLimit() throws {
  for (kind, slew) in [(LeapSecond.insertion, Int64.min), (.deletion, Int64.max),
    (.insertion, Int64.max), (.deletion, Int64.min)] {
    var clock = try #require(SystemClocks(frequency: 1_000_000_000, counter: 0, utc: 0))
    #expect(clock.slewUTC(by: slew, counter: 0) == true)
    #expect(clock.scheduleLeap(kind, startingAtBoot: 0, counter: 0) == true)
    for dt in [UInt64(1_999), 2_000, 86_399, 86_400, 88_000, day / 2, day, day + 2_000] {
      let leap = min(dt, day) / 2000 * 5 / 216, regular = dt / 2000 - leap
      let raw = slew < 0 ? dt - regular : dt + regular
      #expect(clock.read(counter: dt)?.utc == (kind == .insertion ? raw - leap : raw + leap))
    }
    let t = day / 2 + 12_551
    let before = clock.read(counter: t)?.utc
    #expect(clock.slewUTC(by: 0, counter: t) == true)
    #expect(clock.read(counter: t)?.utc == before)
    #expect(clock.stepUTC(to: 12, counter: t) == true)
    #expect(clock.read(counter: t + day)?.utc == 12 + day)
  }
}

@available(macOS 15, *)
@Test func publishesSmearForReadersAndUtcTimers() throws {
  let bytes = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 4096)
  defer { bytes.deallocate() }
  guard let writer = TimePageWriter(freshPage: bytes), let reader = TimePageReader(page: .init(bytes))
  else { Issue.record("page"); return }
  var clock = try #require(SystemClocks(frequency: 1_000_000_000, counter: 0))
  #expect(clock.scheduleLeap(.insertion, startingAtBoot: 0, counter: 0) == false)
  #expect(clock.stepUTC(to: 123, counter: 0) == true)
  #expect(clock.scheduleLeap(.deletion, startingAtBoot: .max - day + 1, counter: 0) == false)
  #expect(clock.scheduleLeap(.deletion, startingAtBoot: 1, counter: 2) == false)
  #expect(clock.scheduleLeap(.deletion, startingAtBoot: 0, counter: 0) == true)
  #expect(writer.publish(clock) == true)
  let counter = day / 2, wall = counter + 500_000_123
  #expect(reader.read(counter: { counter })?.utc == wall)
  var slots = [TimerSlot()]
  try slots.withUnsafeMutableBufferPointer {
    guard var timers = OneShotTimers(storage: $0, identity: 1, domain: .utc, wakesSystem: true) else {
      Issue.record("queue"); return
    }
    let now = try #require(clock.read(counter: 0))
    // A fast smear can skip a nanosecond at a credit boundary.
    let key = timers.arm(deadline: wall - 1, at: now, tolerance: .strict, cookie: 42)
    #expect(key != nil)
    #expect(timers.nextWake(clock: clock, counter: 0, preparingSleep: true) == .atBoot(counter))
    let early = try #require(reader.read { counter - 1 }), due = try #require(reader.read { counter })
    #expect(timers.takeDue(at: early) == nil)
    #expect(timers.takeDue(at: due) == 42)
  }
}
