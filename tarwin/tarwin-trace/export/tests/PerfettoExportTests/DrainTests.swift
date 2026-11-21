import TarwinTrace
import Testing

@testable import PerfettoExport

@Test func kernelTraceProducerDrainsExactPerfettoBytesAfterBackpressure() throws {
  var producer = TraceProducer(capacity: 64)
  var drain = try #require(TraceDrain(source: .kernelCPU, capacity: 64, track: 7))
  var slots = [UInt64: TraceRecord]()
  var head: UInt64 = 0
  var tail: UInt64 = 0
  for i in 0..<70 {
    let record = TraceRecord(monotonicNanos: UInt64(i), kind: .interrupt, subject: 37, value: 2)
    let pushed = producer.push(record, tail, { slots[$0] = $1 }, { head = $0 })
    #expect(pushed)
    let expected = perfettoEvent(
      7, UInt64(i), .instant, "kernel", "interrupt", 2, subject: 37, value: 2)
    let wait = drain.step(
      head: head, copy: { slots[$0] }, counterTrack: { _ in nil }, sink: { _ in false },
      releaseTail: { _ in Issue.record("early tail") })
    #expect(wait == .backpressure && drain.consumed == tail)
    let read = drain.step(
      head: head, copy: { slots[$0] }, counterTrack: { _ in nil }, sink: { $0 == expected },
      releaseTail: { tail = $0 })
    #expect(read == .progress && tail == head)
  }
}

@Test func userRingCannotForgeKernelEventsOrSelectArbitraryTracks() throws {
  var d = try #require(TraceDrain(source: .userThread, capacity: 64, track: 4))
  var publishes = 0
  func step(_ kind: TraceKind, _ time: UInt64, _ head: UInt64, _ counter: UInt64?) -> DrainResult {
    d.step(
      head: head,
      copy: { _ in TraceRecord(monotonicNanos: time, kind: kind, subject: 9, value: 22) },
      counterTrack: { _ in counter }, sink: { _ in true }, releaseTail: { _ in publishes += 1 })
  }
  #expect(step(.fault, 1, 1, nil) == .invalid)
  #expect(step(.userCounter, 1, 1, 4) == .invalid)
  #expect(step(.userBegin, 2, 65, nil) == .invalid)
  #expect(step(.userCounter, 2, 1, 5) == .progress)
  #expect(step(.userEnd, 1, 2, nil) == .invalid)
  #expect(step(.userInstant, 3, 0, nil) == .invalid)
  #expect(step(.userEnd, 3, 1, nil) == .empty)
  #expect(publishes == 1)
}
