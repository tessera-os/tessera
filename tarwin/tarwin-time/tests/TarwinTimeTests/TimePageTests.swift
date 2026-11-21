import TarwinTime
import Testing

@available(macOS 15, *)
@Test func timePageRetriesAcrossPublicationAndSuspend() throws {
  let bytes = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 4096)
  defer { bytes.deallocate() }
  bytes.initializeMemory(as: UInt8.self, repeating: 0xab)
  let page = try #require(TimePageReader(page: .init(bytes)))
  guard let writer = TimePageWriter(freshPage: bytes) else { Issue.record("writer"); return }
  #expect(bytes[4095] == 0)
  #expect(page.read(counter: { 9 }) == nil)
  var clock = try #require(SystemClocks(frequency: 1_000_000_000, counter: 10, utc: 5_000))
  #expect(writer.publish(clock) == true)
  var reads = 0
  let time = page.read {
    if reads == 0 {
      _ = clock.suspend(counter: 15)
      _ = clock.resume(counter: 1, sleepNS: 11)
      _ = writer.publish(clock)
    }
    reads += 1
    return 5
  }
  #expect(reads == 2)
  #expect(time?.monotonic == 9 && time?.boot == 20 && time?.utc == 5_020)
  #expect(clock.suspend(counter: 6) == true)
  #expect(writer.publish(clock) == true)
  #expect(page.read(counter: { Issue.record("sampled while suspended"); return 7 }) == nil)
  _ = clock.resume(counter: 0, sleepNS: 0)
  #expect(writer.publish(clock) == true)
  var attempts = 0
  #expect(page.read(counter: {
    _ = writer.publish(clock)
    attempts += 1
    return 10
  }) == nil)
  #expect(attempts == 8)
  #expect(TimePageReader(page: .init(rebasing: UnsafeRawBufferPointer(bytes)[8...])) == nil)
}
