import TarwinMM
import Testing

@Test func smallZonesNeverChangeTypeAndNeverDrainOnExhaustion() {
  let memory = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 4096)
  defer { memory.deallocate() }
  let raw = UnsafeMutableRawBufferPointer(start: memory, count: 4096)
  for i in raw.indices { raw[i] = 0xbc }
  var slabs = [HeapSlab](repeating: HeapSlab(), count: 2)
  slabs.withUnsafeMutableBufferPointer { meta in
    guard var arena = HeapArena(storage: raw, metadata: meta, policy: .noHardwareTags),
      arena.provision(typeID: 111, sizeClass: 32, slots: 2),
      arena.provision(typeID: 222, sizeClass: 32, slots: 1)
    else {
      Issue.record("zone setup")
      return
    }
    func cleared(_ p: UnsafeRawPointer) -> Bool {
      UnsafeRawBufferPointer(start: p, count: 32).allSatisfy { $0 == 0 }
    }
    let wrong = arena.allocate(size: 25, alignment: 16, typeID: 333)
    #expect(wrong == nil)
    guard let a = arena.allocate(size: 25, alignment: 16, typeID: 111),
      let b = arena.allocate(size: 25, alignment: 16, typeID: 111),
      let c = arena.allocate(size: 25, alignment: 16, typeID: 222)
    else {
      Issue.record("capacity")
      return
    }
    #expect(
      a != b && b != c && a != c && UInt(bitPattern: c) % 32 == 0 && cleared(a) && cleared(b)
        && cleared(c))
    let prefix = arena.free(a + 1)
    #expect(!prefix)
    for i in 0..<32 { a.storeBytes(of: UInt8(0xac), toByteOffset: i, as: UInt8.self) }
    let first = arena.free(a)
    let twice = arena.free(a)
    #expect(first && !twice)
    guard let batch = arena.beginQuarantine() else {
      Issue.record("expected batch")
      return
    }
    let later = arena.free(b)
    let early = arena.allocate(size: 25, alignment: 16, typeID: 111)
    let nested = arena.beginQuarantine()
    #expect(later && early == nil && nested == nil)
    let ended = arena.completeQuarantine(batch)
    let stale = arena.completeQuarantine(batch)
    let ready = arena.allocate(size: 32, alignment: 32, typeID: 111)
    let stillHeld = arena.allocate(size: 32, alignment: 32, typeID: 111)
    let otherBucket = arena.allocate(size: 32, alignment: 32, typeID: 222)
    #expect(ended && !stale && ready == a && cleared(a) && stillHeld == nil && otherBucket == nil)
    guard let next = arena.beginQuarantine() else {
      Issue.record("late free lost")
      return
    }
    let old = arena.completeQuarantine(batch)
    let fresh = arena.completeQuarantine(next)
    let second = arena.allocate(size: 32, alignment: 32, typeID: 111)
    #expect(!old && fresh && second == b && raw[96...].allSatisfy { $0 == 0xbc })
  }
}

@Test func smallZoneBoundsAndTagPolicy() {
  let p = UnsafeMutableRawPointer.allocate(byteCount: 2048, alignment: 1024)
  defer { p.deallocate() }
  let memory = UnsafeMutableRawBufferPointer(start: p + 1, count: 2047)
  var slabs = [HeapSlab](repeating: HeapSlab(), count: 2)
  slabs.withUnsafeMutableBufferPointer { meta in
    let tagged = HeapArena(storage: memory, metadata: meta, policy: .synchronousMTE)
    let rejected = tagged == nil
    #expect(rejected)
    guard var heap = HeapArena(storage: memory, metadata: meta, policy: .noHardwareTags) else {
      Issue.record("small arena setup")
      return
    }
    for (size, n) in [(0, 1), (24, 1), (131072, 1), (1024, 2), (16, 0), (16, 65)] {
      let provisioned = heap.provision(typeID: 1, sizeClass: size, slots: n)
      #expect(!provisioned)
    }
    let ok = heap.provision(typeID: 1, sizeClass: 16, slots: 64)
    #expect(ok)
    for i in 0..<64 {
      let result = heap.allocate(size: 1, alignment: 16, typeID: 1)
      #expect(result == p + 16 + i * 16)
    }
    let full = heap.allocate(size: 1, alignment: 16, typeID: 1)
    #expect(full == nil)
    for (size, align) in [(0, 16), (-1, 16), (2, 0), (2, 3), (65537, 16)] {
      let result = heap.allocate(size: size, alignment: align, typeID: 1)
      #expect(result == nil)
    }
  }
}
