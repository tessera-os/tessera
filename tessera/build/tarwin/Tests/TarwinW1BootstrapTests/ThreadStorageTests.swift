import Testing

@testable import TarwinW1Bootstrap

@Test func firstStackCountsWholeReservationsAndRejectsMissingEntropy() {
  let page: UInt64 = 16384
  let lo: UInt64 = 1 << 43
  let hi: UInt64 = 1 << 46
  // A one-page stack, a one-page shadow and the surrounding TCB and guards.
  let count = (hi - lo) / page - 10 + 1
  for (word, first) in [(count, lo), (2 * count - 1, hi - 10 * page)] {
    var draws = [0, word, 7].makeIterator()
    guard let t = W1ThreadPlacement(stackBytes: page, draw: { draws.next() }) else {
      Issue.record("valid placement rejected")
      return
    }
    #expect(t.stack == first + 4 * page..<first + 5 * page && t.tcb == first + 6 * page)
    #expect(t.shadow == first + 8 * page..<first + 9 * page && draws.next() == nil)
  }
  for size in [0, page - 1, 48 << 40, hi - lo, UInt64.max] {
    let denied =
      W1ThreadPlacement(
        stackBytes: size,
        draw: {
          Issue.record("unexpected draw")
          return nil
        }) == nil
    #expect(denied)
  }
  var source = [UInt64.max].makeIterator()
  let exhausted = W1ThreadPlacement(stackBytes: page, draw: { source.next() }) == nil
  #expect(exhausted)
  var zeros = 0
  let exhaustedRetries =
    W1ThreadPlacement(
      stackBytes: page,
      draw: {
        zeros += 1
        return 0
      }) == nil
  #expect(exhaustedRetries && zeros == 64)
}
