import Testing

@testable import TarwinTrace

nonisolated(unsafe) private var panicBytes: [UInt8] = []
func putByte(_ at: UInt64, _ value: UInt8) { panicBytes[Int(at)] = UInt8(value) }
func readByte(_ at: UInt64) -> UInt8 { return UInt8(panicBytes[Int(at)]) }
func payload(_ at: UInt64) -> UInt8 { return UInt8(at + 40) }
func persist() {}

@Test
func panicCommitIsBoundedAndTornRecordsAreRejected() {
  panicBytes = []
  for _ in 0..<32 { panicBytes.append(0) }
  var writer = PanicWriter(capacity: 32)
  #expect(writer.begin(putByte, persist) == true)
  #expect(writer.section(1, 16, payload, putByte) == false)
  #expect(writer.section(1, 15, payload, putByte) == true)
  #expect(panicSize(32, readByte) == 0)
  #expect(writer.commit(putByte, persist) == true)
  #expect(panicSize(32, readByte) == 32)
  #expect(panicSize(31, readByte) == 0)
  panicBytes[31] = 0
  #expect(panicSize(32, readByte) == 0)
}

nonisolated(unsafe) private var lastSlot: UInt64 = 99
nonisolated(unsafe) private var lastHead: UInt64 = 0
func storeRecord(_ slot: UInt64, _ value: TraceRecord) { lastSlot = slot }
func headRelease(_ head: UInt64) { lastHead = head }

@Test
func invalidSharedTailCannotAdvancePrivateRingHead() {
  var producer = TraceProducer(capacity: 64)
  producer.produced = 64
  let event = TraceRecord(monotonicNanos: 3, kind: .contextSwitch, subject: 1, value: 4)
  #expect(producer.push(event, 0, storeRecord, headRelease) == false)
  #expect(producer.push(event, 65, storeRecord, headRelease) == false)
  #expect(producer.push(event, 1, storeRecord, headRelease) == true)
  #expect(lastSlot == 0)
  #expect(lastHead == 65)
  #expect(producer.dropped == 2)
  #expect(!counterAccess(.system, 4, 4, false))
}
