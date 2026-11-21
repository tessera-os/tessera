import TarwinBoot
import Testing

@testable import Tarboot

private func record(_ base: UInt64, _ length: UInt64, type: UInt32, attrs: UInt64 = 8)
  -> FirmwareRegion
{
  FirmwareRegion(base: base, length: length, type: type, attributes: attrs)
}

@Test func firmwareMapSplitsOnlyOwnedPagesAndPreservesFirmware() {
  let p: UInt64 = 4096
  let efi = [
    record(p, 7 * p, type: 2), record(10 * p, p, type: 4), record(11 * p, p, type: 7),
    record(12 * p, p, type: 7, attrs: 0x1008), record(13 * p, p, type: 7, attrs: (1 << 62) | 8),
  ]
  let archive = LoaderExtent(base: 6 * p, length: p, kind: 7)
  let handoff = LoaderExtent(base: 2 * p, length: 2 * p, kind: 8)
  var bytes = [UInt8](repeating: 0xaa, count: 321)
  let n = efi.withUnsafeBufferPointer { regions in
    bytes.withUnsafeMutableBytes {
      writeHandoffMap(
        regions, archive: archive, handoff: handoff, into: .init(rebasing: $0[1..<289]))
    }
  }
  #expect(n == 9 && bytes[0] == 0xaa && bytes[289...].allSatisfy { $0 == 0xaa })
  let expected: [(UInt64, UInt64, UInt8)] = [
    (1, 1, 1), (2, 2, 8), (4, 2, 1), (6, 1, 7), (7, 1, 1), (10, 1, 1), (11, 1, 0), (12, 1, 1),
    (13, 1, 1),
  ]
  bytes.withUnsafeBytes { data in
    for (i, entry) in expected.enumerated() {
      let b = 1 + i * 32
      #expect(data.loadUnaligned(fromByteOffset: b, as: UInt64.self) == entry.0 * p)
      #expect(data.loadUnaligned(fromByteOffset: b + 8, as: UInt64.self) == entry.1 * p)
      #expect(data[b + 16] == entry.2 && data[b + 24..<b + 32].allSatisfy { $0 == 0 })
    }
  }
  for (base, length): (UInt64, UInt64) in [
    (2 * p, p), (8 * p, p), (11 * p, p), (7 * p, 2 * p), (6 * p + 1, p), (6 * p, 0),
  ] {
    let bad = LoaderExtent(base: base, length: length, kind: 7)
    let result = efi.withUnsafeBufferPointer { regions in
      bytes.withUnsafeMutableBytes {
        writeHandoffMap(regions, archive: bad, handoff: handoff, into: $0)
      }
    }
    #expect(result == nil)
  }
  let short = efi.withUnsafeBufferPointer { regions in
    bytes.withUnsafeMutableBytes {
      writeHandoffMap(
        regions, archive: archive, handoff: handoff, into: .init(rebasing: $0[..<287]))
    }
  }
  #expect(short == nil)
}

@Test func handoffReaderChecksEveryDescriptorAndExternalOwner() {
  let p: UInt64 = 4096
  var info = emptyBootInfo()
  info.year = 26
  info.month = 11
  info.week = 1
  info.rsdp = p
  info.bootSet = 8 * p
  info.bootSetSize = p - 1
  info.mapAddress = 4 * p
  info.mapCount = 2
  let block = (0..<4096).map { bootInfoByte(info, offset: UInt64($0)) }
  let entries = [
    PhysicalRegion(base: 3 * p, length: 2 * p, kind: 8, attributes: 8),
    PhysicalRegion(base: 8 * p, length: p, kind: 7, attributes: 8),
  ]
  let map = entries.flatMap { entry in (0..<32).map { regionByte(entry, offset: UInt64($0)) } }
  func accepts(_ b: [UInt8], _ m: [UInt8], blockAt: UInt64 = 12288, mapAt: UInt64 = 16384) -> Bool {
    b.withUnsafeBytes { raw in
      m.withUnsafeBytes {
        readHandoff(block: raw, at: blockAt, map: $0, at: mapAt) != nil
      }
    }
  }
  #expect(accepts(block, map))
  var debug = block
  debug[177] = 2
  let fixed = DebugQEMUFixedGeneration(low: 0x0807060504030201, high: 0x100f0e0d0c0b0a09)!
  #expect(DebugQEMUFixedGeneration(low: 0, high: 0) == nil)
  #expect(debug.withUnsafeMutableBytes { fixed.encode(in: $0) })
  func claim(_ b: [UInt8], _ m: [UInt8]) -> DebugQEMUFixedGeneration? {
    b.withUnsafeBytes { raw in m.withUnsafeBytes {
      readFixedDebugQEMUHandoff(block: raw, at: 3*p, map: $0, at: 4*p)?.generation
    } }
  }
  #expect(claim(debug, map) == fixed && !accepts(debug, map))
  #expect(Array(debug[216..<224]) == Array("DBGQGEN1".utf8))
  #expect(Array(debug[224..<240]) == Array(1...16))
  #expect(claim(block, map) == nil && claim(debug, Array(map.dropLast())) == nil)
  for i in [7,16,177,216,240,4095] {
    var wrong = debug
    wrong[i] ^= 1
    #expect(claim(wrong, map) == nil)
  }
  var zero = debug
  zero.replaceSubrange(224..<240, with: repeatElement(0, count: 16))
  #expect(claim(zero, map) == nil)
  var normal = block
  #expect(!normal.withUnsafeMutableBytes { fixed.encode(in: $0) } && normal == block)
  #expect(!accepts(Array(block.dropLast()), map))
  #expect(!accepts(block, Array(map.dropLast())))
  #expect(!accepts(block, map, blockAt: 4 * p))
  #expect(!accepts(block, map, mapAt: 6 * p))
  #expect(!accepts(block, map, blockAt: 2 * p))
  for i in [16, 48, 63] {
    var bad = map
    bad[i] ^= 1
    #expect(!accepts(block, bad))
  }
  var bad = block
  bad[88 + 1] = 0xff
  #expect(!accepts(bad, map))
}
