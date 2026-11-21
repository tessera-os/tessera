import Synchronization
import TarwinTime
import Testing

@available(macOS 15, *)
@Test func kernelAndUserObserveTheSameClockTransitions() throws {
  let bytes = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 4096)
  defer { bytes.deallocate() }
  let seed = try #require(SystemClocks(frequency: 1_000_000_000, counter: 0))
  guard var owner = PublishedClocks(freshPage: bytes, clock: seed),
    let reader = TimePageReader(page: .init(bytes)) else { Issue.record("page"); return }
  let seq = bytes.baseAddress!.assumingMemoryBound(to: Atomic<UInt64>.self)
  #expect(owner.update(.slewUTC(10), counter: 0) == false)
  #expect(owner.update(.resume(sleptNS: 3), counter: 0) == false)
  #expect(seq.pointee.load(ordering: .acquiring) == 2)
  for update in [ClockUpdate.stepUTC(50), .leap(.insertion, startingAtBoot: 2), .slewUTC(7)] {
    #expect(owner.update(update, counter: 2) == true)
    let kernel = try #require(owner.snapshot?.read(counter: 1_000_000))
    #expect(reader.read(counter: { 1_000_000 })?.utc == kernel.utc)
  }
  #expect(owner.update(.suspend, counter: 2_000_000) == true)
  #expect(reader.read(counter: { Issue.record("suspended counter"); return 0 }) == nil)
  #expect(owner.update(.resume(sleptNS: .max), counter: 0) == false)
  #expect(owner.snapshot?.read(counter: 10) == nil)
  #expect(owner.update(.resume(sleptNS: 20_000_000), counter: 0) == true)
  let resumed = try #require(reader.read(counter: { 10 }))
  #expect(resumed.boot == 22_000_010 && resumed.utc == owner.snapshot?.read(counter: 10)?.utc)
  seq.pointee.store(.max - 1, ordering: .sequentiallyConsistent)
  #expect(owner.update(.stepUTC(4), counter: 10) == false)
  #expect(owner.snapshot == nil)
  #expect(reader.read(counter: { Issue.record("exhausted sequence"); return 10 }) == nil)
  #expect(owner.update(.stepUTC(0), counter: 20) == false)
}
