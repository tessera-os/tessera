import TarwinMM
import Testing

@Test func taggedBlocksSurviveCompactionAndSlotReuse() {
  for pageSize in [4096, 16384] {
    var backing = [UInt8](repeating: 0xa7, count: pageSize)
    var slots = [CompressedSlot](repeating: .init(), count: 2)
    backing.withUnsafeMutableBufferPointer { bytes in
      slots.withUnsafeMutableBufferPointer { meta in
        guard var pool = CompressedSegment(identity: 1, storage: bytes, slots: meta) else { Issue.record(); return }
        var table = TestTable(), plain = buffer(UInt64(pageSize))
        var tagged = buffer(frameBytes(UInt64(pageSize), tagged: true))
        for i in tagged.data.indices { tagged.data[i] = UInt8(i < pageSize ? i % 13 : i % 255) }
        guard let a = pool.store(plain, tagged: false, table: &table),
          let b = pool.store(tagged, tagged: true, table: &table) else { Issue.record(); return }
        #expect(pool.store(plain, tagged: false, table: &table) == nil)
        #expect(UInt64(pool.usedBytes) == a.storedBytes + b.storedBytes)
        #expect(pool.discard(a) == true)
        #expect(pool.discard(a) == false)
        guard let c = pool.store(plain, tagged: false, table: &table) else { Issue.record(); return }
        #expect(pool.restore(a, into: &plain, tagged: false) == false)
        #expect(pool.restore(b, into: &plain, tagged: false) == false)
        var output = buffer(tagged.size)
        #expect(pool.restore(b, into: &output, tagged: true) == true)
        #expect(output.data == tagged.data)
        #expect(pool.discard(c) == true)
        #expect(pool.discard(b) == true)
        #expect(pool.usedBytes == 0)
      }
    }
  }
}

@Test func incompressibleFrameNeverDisplacesResidentOrPreviouslyStoredPage() {
  var backing = [UInt8](repeating: 0, count: 4096)
  var slots = [CompressedSlot](repeating: .init(), count: 2)
  backing.withUnsafeMutableBufferPointer { bytes in
    slots.withUnsafeMutableBufferPointer { meta in
      guard var pool = CompressedSegment(identity: 7, storage: bytes, slots: meta) else { Issue.record(); return }
      var frame = buffer(4096), table = TestTable()
      guard let first = pool.store(frame, tagged: false, table: &table) else { Issue.record(); return }
      var x: UInt32 = 17
      for i in frame.data.indices {
        x ^= x << 13; x ^= x >> 17; x ^= x << 5
        frame.data[i] = UInt8(truncatingIfNeeded: x)
      }
      #expect(pool.store(frame, tagged: false, table: &table) == nil)
      #expect(UInt64(pool.usedBytes) == first.storedBytes)
      #expect(pool.restore(first, into: &frame, tagged: false) == true)
      #expect(frame.data.allSatisfy { $0 == 0 })
    }
  }
}
