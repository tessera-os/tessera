import TarwinTime
import Testing

@Test func corroboratesWholeIntervalNotJustMidpoint() throws {
  let a = try #require(CounterCrossStamp(before: 100, referenceNS: 1_000, after: 101))
  func check(_ hz: UInt64, _ low: UInt64, _ ref: UInt64, _ high: UInt64) -> Bool {
    guard let b = CounterCrossStamp(before: low, referenceNS: ref, after: high) else { return false }
    return BootCounterRate(advertisedHz: hz, first: a, last: b, minimumNS: 9_000,
      maximumErrorNS: 20) != nil
  }
  #expect(check(100_000_000, 1100, 11_000, 1102))
  #expect(!check(100_000_000, 1098, 11_000, 1103))
  #expect(!check(10_000_000, 1100, 11_000, 1102))
  #expect(!check(0, 1100, 11_000, 1102))
  #expect(!check(100_000_000, 101, 11_000, 1102))
  #expect(!check(1, .max - 1, .max, .max))
  #expect(!check(100_000_000, 1100, 900, 1102))
  #expect(!check(100_000_000, 1102, 11_000, 1100))
  #expect(!check(100_000_000, 110, 1100, 111))
}

@Test func boundedRendezvousRejectsStalePeerOrLongRoundTrip() throws {
  func sample(_ a: UInt64, _ b: UInt64, _ c: UInt64) -> CounterRendezvous? {
    CounterRendezvous(before: a, peer: b, after: c, maximumSpan: 10)
  }
  let first = try #require(sample(10, 12, 20)), next = try #require(sample(30, 30, 32))
  #expect(next.follows(first, minimumTicks: 10))
  #expect(!next.follows(first, minimumTicks: 11))
  #expect(!first.follows(next, minimumTicks: 1))
  #expect(sample(20, 19, 21) == nil)
  #expect(sample(20, 22, 21) == nil)
  #expect(sample(20, 22, 31) == nil)
  #expect(sample(.max, 0, 1) == nil)
}
