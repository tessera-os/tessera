import TarwinMM
import Testing

@Test func imagePairsCommitInOrderOrNotAtAll() {
  for p: UInt64 in [4096, 16384] {
    let base: UInt64 = 1 << 32
    func span(_ n: UInt64) -> Range<UInt64> { (base + n * p)..<(base + (n + 1) * p) }
    var buffer = [span(2), span(4), span(0), span(0), span(0), span(0)]
    buffer.withUnsafeMutableBufferPointer { slots in
      guard var map = ImageReservations(storage: slots, used: 2, pageSize: p, userBits: 47)
      else { Issue.record("valid reservations rejected"); return }
      func reserve(_ a: Range<UInt64>, _ b: Range<UInt64>) -> Bool { map.reservePair(a, b) }
      for (a, b) in [
        (span(0), span(2)), (span(4), span(5)), (span(3), span(3)), (base..<base, span(1)),
        (base + 1..<base + p, span(1)), (span(0), (1 << 43)..<((1 << 43) + p)),
      ] {
        let before = Array(slots)
        #expect(!reserve(a, b))
        #expect(map.count == 2 && Array(slots) == before)
      }
      #expect(reserve(span(5), span(1)))
      #expect(Array(map.occupied) == [span(1), span(2), span(4), span(5)])
      #expect(reserve(span(0), span(3)))
      let full = (0..<6).map { span(UInt64($0)) }
      #expect(Array(map.occupied) == full)
      #expect(!reserve(span(6), span(7)))
      #expect(Array(map.occupied) == full)
    }
  }
}

@Test func initialImageMapMustBeOrderedDisjointAndInRange() {
  let base: UInt64 = 1 << 32
  let a = base..<base + 4096
  let b = a.upperBound..<a.upperBound + 4096
  for records in [[b, a], [a, a], [a, base..<base], [a, 0..<4096]] {
    var storage = records
    storage.withUnsafeMutableBufferPointer { slots in
      if let _ = ImageReservations(storage: slots, used: 2, pageSize: 4096, userBits: 56) {
        Issue.record("accepted invalid occupied map")
      }
    }
  }
}
