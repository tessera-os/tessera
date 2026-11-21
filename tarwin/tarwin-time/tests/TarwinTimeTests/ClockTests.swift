import TarwinTime
import Testing

@Test func clockTests() {
  #expect(!counterDuration(1, frequency: 0).valid)
  #expect(!counterDuration(0xffff_ffff_ffff_ffff, frequency: 1).valid)
  #expect(counterDuration(20, frequency: 3).ns == 6_666_666_666)
  #expect(counterDuration(0, frequency: 100).ns == 0)
  #expect(
    counterDuration(0xffff_ffff_ffff_fffe, frequency: 0xffff_ffff_ffff_ffff).ns == 999_999_999)
  let full = counterDuration(0xffff_ffff_ffff_ffff, frequency: 1_000_000_000)
  #expect(full.valid)
  #expect(full.ns == 0xffff_ffff_ffff_ffff)
  #expect(
    counterDuration(0x8000_0000_0000_0000, frequency: 0xffff_ffff_ffff_ffff).ns == 500_000_000)
  #expect(utcSlewLimit(100, elapsed: 199999) == 99)
  #expect(backgroundSlack(0xffff_ffff_ffff_ffff) == 1_000_000_000)
  #expect(coalesceDeadline(100, slack: 4, programmed: 99) == 100)
  #expect(coalesceDeadline(100, slack: 4, programmed: 104) == 104)
  #expect(coalesceDeadline(100, slack: 4, programmed: 105) == 100)
  #expect(lockupCode(20_000_000_000, lastScheduled: 20_000_000_000, lastInterrupt: 0) == 6)
  #expect(lockupCode(9_999_999_999, lastScheduled: 0, lastInterrupt: 0) == 0)
  #expect(lockupCode(10_000_000_000, lastScheduled: 0, lastInterrupt: 10_000_000_000) == 6)
}
