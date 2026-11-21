import TarwinTime
import Testing

@Test func counterDomainAcrossSleep() throws {
  #expect(SystemClocks(frequency: 0, counter: 0) == nil)
  var clock = try #require(SystemClocks(frequency: 3, counter: 9))
  #expect(clock.read(counter: 8) == nil)
  #expect(clock.read(counter: 10)?.utc == nil)
  #expect(clock.slewUTC(by: 1, counter: 10) == false)
  #expect(clock.resume(counter: 10, sleepNS: 1) == false)
  #expect(clock.stepUTC(to: 12, counter: 10) == true)
  #expect(clock.suspend(counter: 9) == false)
  #expect(clock.suspend(counter: 12) == true)
  #expect(clock.read(counter: 50) == nil)
  #expect(clock.suspend(counter: 50) == false)
  #expect(clock.resume(counter: 0, sleepNS: .max) == false)
  #expect(clock.resume(counter: 1, sleepNS: 4_000_000_000) == true)
  let t = try #require(clock.read(counter: 4))
  #expect(t.monotonic == 2_000_000_000)
  #expect(t.boot == 6_000_000_000)
  #expect(t.utc == 5_666_666_679)
}

@Test func slewInterpolatesAndStopsWithoutClockSteps() throws {
  var clock = try #require(SystemClocks(frequency: 1_000_000_000, counter: 0, utc: 2))
  #expect(clock.slewUTC(by: 10, counter: 0) == true)
  #expect(clock.read(counter: 1_999)?.utc == 2_001)
  #expect(clock.read(counter: 2_000)?.utc == 2_003)
  #expect(clock.read(counter: 22_000)?.utc == 22_012)
  #expect(clock.slewUTC(by: .min, counter: 22_000) == true)
  #expect(clock.slewUTC(by: 0, counter: 21_999) == false)
  #expect(clock.stepUTC(to: 0, counter: 21_999) == false)
  #expect(clock.read(counter: 24_000)?.utc == 24_011)
  #expect(clock.stepUTC(to: 0, counter: 24_000) == true)
  #expect(clock.read(counter: 26_000)?.utc == 2_000)
  #expect(clock.stepUTC(to: .max, counter: 26_000) == true)
  #expect(clock.read(counter: 26_001)?.monotonic == 26_001)
  #expect(clock.read(counter: 26_001)?.utc == nil)
}

@Test func keepsFractionalTicksAcrossPowerCycles() throws {
  var clock = try #require(SystemClocks(frequency: 3, counter: 0))
  for _ in 0..<3 {
    #expect(clock.suspend(counter: 1) == true)
    #expect(clock.resume(counter: 0, sleepNS: 10) == true)
  }
  #expect(clock.read(counter: 0)?.monotonic == 1_000_000_000)
  #expect(clock.read(counter: 0)?.boot == 1_000_000_030)
  #expect(clock.read(counter: .max) == nil)
}
