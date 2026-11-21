import TarwinTrace
import Testing

@Test func logFilterSkipsWorkAndPublishesBoundedPrivateBytes() {
  var filter = KernelLogFilter(defaultLevel: .warning)
  filter.set(.security, minimum: .info)
  filter.set(.gpu, minimum: nil)
  var log = KernelLogProducer(capacity: 64)
  var samples = 0
  var reads = 0
  var stores = 0
  var head: UInt64 = 0
  func emit(_ category: KernelCategory, _ level: KernelLogLevel, length: UInt64) -> LogResult {
    log.record(
      category, level, filter: filter,
      monotonic: {
        samples += 1
        return 17
      },
      length: length,
      readByte: {
        reads += 1
        return UInt8($0 & 255)
      }, tail: { 0 },
      write: { slot, entry in
        #expect(slot == head && entry.monotonicNanos == 17 && entry.category == category)
        #expect(entry.length == UInt16(min(256, length)) && entry.truncated == (length > 256))
        if length > 256 { #expect(entry.bytes[255] == 255) }
        if length < 2 { #expect(entry.bytes[2] == 0) }
        stores += 1
      },
      publish: {
        #expect(stores == Int($0))
        head = $0
      })
  }
  #expect(emit(.gpu, .fault, length: 8) == .filtered)
  #expect(emit(.vm, .notice, length: 8) == .filtered)
  #expect(samples == 0 && reads == 0)
  #expect(emit(.security, .info, length: 300) == .stored)
  for _ in 1..<64 { #expect(emit(.vm, .warning, length: 1) == .stored) }
  #expect(emit(.panic, .fault, length: .max) == .full)
  #expect(head == 64 && samples == 64 && reads == 319 && log.dropped == 1)
}
