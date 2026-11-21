import Testing
@testable import Tarboot

@Test func fullVirtualEntropyOrNoPlacement() throws {
  let align: UInt64 = 1 << 21
  let slots: UInt64 = 1 << 18
  let start: UInt64 = 0xffff_8000_0000_0000
  let end = start + (slots - 1) * align + 4096
  for word: UInt64 in [0, 1, slots - 1, slots, .max] {
    #expect(virtualBase(region: start..<end, bytes: 4096, alignment: align, word: word) == start + word % slots * align)
  }
  #expect(virtualBase(region: start..<(end-1), bytes: 4096, alignment: align, word: 0) == nil)
  #expect(virtualBase(region: start..<end, bytes: .max, alignment: align, word: 0) == nil)
  #expect(virtualBase(region: (start+1)..<end, bytes: 4096, alignment: align, word: 0) == nil)
  #expect(virtualBase(region: 0..<end, bytes: 4096, alignment: align, word: 0) == nil)
}

@Test func weightedPhysicalSlotsExcludeReservedAndWrappingExtents() {
  let p: UInt64 = 4096
  func region(_ base: UInt64, _ pages: UInt64, type: UInt32 = 7, attrs: UInt64 = 8) -> FirmwareRegion {
    FirmwareRegion(base: base*p, length: pages*p, type: type, attributes: attrs)
  }
  let map = [region(0,3), region(3,6,type: 2), region(9,4,attrs: 8 | (1<<18)), region(13,5),
    region(20,1,attrs: 0), region(21,2,attrs: 8 | (1<<63))]
  map.withUnsafeBufferPointer { entries in
    for (rank, expected): (UInt64, UInt64) in [(0,1),(1,2),(2,13),(3,14),(4,15),(5,16),(6,17)] {
      #expect(physicalBase(entries, bytes: p, alignment: p, word: 7+rank) == expected*p)
    }
    for (word, expected): (UInt64, UInt64) in [(2,14), (3,16)] {
      #expect(physicalBase(entries, bytes: 2*p, alignment: 2*p, word: word) == expected*p)
    }
    #expect(physicalBase(entries, bytes: 6*p, alignment: p, word: .max) == nil)
  }
  #expect(unbiasedRank(0, count: 3) == nil)
  #expect(unbiasedRank(1, count: 3) == 1)
  #expect(unbiasedRank(0, count: 0) == nil)
  #expect(CandidateSpan(FirmwareRegion(base: .max-4095, length: 4096, type: 7, attributes: 8), bytes: p, alignment: p) == nil)
}

#if arch(arm64)
  nonisolated(unsafe) private var rngTable: UnsafeRawPointer?
  @Test func failedFirmwareSeedIsNeverPublished() {
    let locate: LocateProtocol = { id, _, out in
      precondition(id.load(as: UInt64.self) == 0x433d_eade_3152_bca5)
      out.pointee = rngTable
      return 0
    }
    let generate: RandomBytes = { _, algorithm, count, output in
      precondition(algorithm?.load(as: UInt64.self) == 0x4827_b6e8_e431_76d7 && count == 64)
      output.storeBytes(of: UInt64.max, as: UInt64.self)
      return 1
    }
    var table = [UInt64](repeating: 0, count: 2)
    var storage = [UInt8](repeating: 127, count: 66)
    table.withUnsafeMutableBytes { raw in
      raw.storeBytes(of: generate, toByteOffset: 8, as: RandomBytes.self)
      rngTable = UnsafeRawPointer(raw.baseAddress!)
      defer { rngTable = nil }
      storage.withUnsafeMutableBytes { bytes in
        let result = FirmwareRNG.readSeed(locate, into: .init(rebasing: bytes[1...64]))
        #expect(!result)
      }
    }
    #expect(storage[0] == 127 && storage[65] == 127 && storage[1...64].allSatisfy { $0 == 0 })
    if #available(macOS 26, *) {
      let handles: LocateHandles = { kind, _, _, length, out in
        precondition(kind == 2 && length.pointee >= 8)
        out.storeBytes(of: UInt(1), as: UInt.self)
        length.pointee = 8
        return 0
      }
      let lookup: HandleProtocol = { handle, _, out in
        precondition(UInt(bitPattern: handle) == 1)
        out.pointee = rngTable
        return 0
      }
      let fill: RandomBytes = { _, alg, count, output in
        precondition(alg?.load(as: UInt64.self) == 0x4827_b6e8_e431_76d7 && count == 64)
        for i in 0..<Int(count) { output.storeBytes(of: UInt8(i), toByteOffset: i, as: UInt8.self) }
        return 0
      }
      table.withUnsafeMutableBytes { raw in
        raw.storeBytes(of: fill, toByteOffset: 8, as: RandomBytes.self)
        rngTable = UnsafeRawPointer(raw.baseAddress!)
        defer { rngTable = nil }
        storage.withUnsafeMutableBytes { bytes in
          #expect(FirmwareRNG.readSeed(nil, handles: handles, protocolFor: lookup,
            into: .init(rebasing: bytes[1...64])))
        }
      }
      #expect(storage == [127] + (0..<64).map(UInt8.init) + [127])
    }
  }
#endif
