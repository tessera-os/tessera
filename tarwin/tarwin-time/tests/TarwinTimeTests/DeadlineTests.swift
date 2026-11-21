import TarwinTime
import Testing

@available(macOS 15, *)
@Test func earliestRepresentableTick() {
  let values: [UInt64] = [0, 1, 3, 999_999_999, 1_000_000_000, 1_000_000_001, .max - 1, .max]
  for hz in values {
    for ns in values {
      let exact = (UInt128(hz) * UInt128(ns) + 999_999_999) / 1_000_000_000
      let expected = hz == 0 ? nil : UInt64(exactly: exact)
      #expect(deadlineTicks(ns, frequency: hz) == expected)
    }
  }
}

@Test func absoluteCompareSurvivesCounterRebase() throws {
  var c = try #require(SystemClocks(frequency: 3, counter: 90))
  #expect(c.compareValue(forMonotonic: 1, counter: 90) == 91)
  #expect(c.compareValue(forMonotonic: 1, counter: 92) == 92)
  #expect(c.suspend(counter: 92) == true)
  #expect(c.compareValue(forMonotonic: 1, counter: 0) == nil)
  #expect(c.resume(counter: 0, sleepNS: 10_000_000_000) == true)
  #expect(c.compareValue(forMonotonic: 1_000_000_000, counter: 0) == 1)
  let edge = try #require(SystemClocks(frequency: 1, counter: .max))
  #expect(edge.compareValue(forMonotonic: 1, counter: .max) == nil)
}
