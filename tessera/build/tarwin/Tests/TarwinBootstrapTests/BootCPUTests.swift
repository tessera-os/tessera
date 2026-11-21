import TarwinBootstrap
import TarwinTime
import Testing

@Test func bootHandoffAndTimer() {
  var cpu = BootCPU()
  guard cpu.start(counter: 500, frequency: 32_768, initialContext: 5) else {
    Issue.record("initial context rejected")
    return
  }
  let first = cpu.service(.poll, counter: 500)
  #expect(first?.previous == 0 && first?.next == 5)
  #expect(first?.sliceCounter == nil)
  let two = cpu.service(.add(context: 8, qos: 3), counter: 500)
  #expect(two?.next == 5 && two?.sliceCounter == 599)
  #expect(cpu.service(.poll, counter: 598)?.next == 5)
  #expect(cpu.service(.poll, counter: 599)?.next == 8)
  #expect(cpu.service(.wake(context: 8), counter: 599) == nil)
  let only = cpu.service(.sleepRunning, counter: 600)
  #expect(only?.previous == 8 && only?.next == 5 && only?.sliceCounter == nil)
  let idle = cpu.service(.retire(context: 5), counter: 601)
  #expect(idle?.next == 0 && idle?.sliceCounter == nil)
  #expect(cpu.service(.wake(context: 8), counter: 600) == nil)
  #expect(cpu.service(.wake(context: 8), counter: 601)?.next == 8)
}

@Test func invalidBootstrapAndClockLimits() {
  var cpu = BootCPU()
  #expect(cpu.service(.poll, counter: 0) == nil)
  #expect(cpu.start(counter: 0, frequency: 0, initialContext: 1) == false)
  #expect(cpu.start(counter: 0, frequency: 1, initialContext: 0) == false)
  guard cpu.start(counter: .max - 1, frequency: .max, initialContext: 1) else {
    Issue.record("unexpected refusal")
    return
  }
  #expect(cpu.start(counter: 0, frequency: 1, initialContext: 3) == false)
  #expect(cpu.service(.add(context: 1, qos: 3), counter: .max) == nil)
  #expect(cpu.service(.add(context: 2, qos: 6), counter: .max) == nil)
  #expect(cpu.service(.add(context: 2, qos: 3), counter: .max)?.sliceCounter == .max)
}

@Test func localComparatorTakesEarlierObjectOrSlice() throws {
  var cpu = BootCPU()
  let clock = try #require(SystemClocks(frequency: 32_768, counter: 500))
  guard cpu.start(counter: 500, frequency: 32_768, initialContext: 1),
    let pair = cpu.service(.add(context: 2, qos: 3), counter: 500),
    let slice = pair.sliceCounter else { Issue.record("no competing context"); return }
  var programmed: UInt64?
  func set(_ target: UInt64?) -> Bool { programmed = target; return true }
  #expect(pair.programDeadline(timers: .atBoot(1), clock: clock, counter: 500, set: set))
  #expect(programmed == 501)
  #expect(pair.programDeadline(timers: .atBoot(80_000_000), clock: clock, counter: 500, set: set))
  #expect(programmed == slice)
  #expect(!pair.programDeadline(timers: .unavailable, clock: clock, counter: 500, set: { _ in Issue.record(); return true }))
  #expect(!pair.programDeadline(timers: .atBoot(1), clock: clock, counter: 499, set: { _ in Issue.record(); return true }))
  #expect(!pair.programDeadline(timers: .none, clock: clock, counter: 500, set: { _ in false }))
}
