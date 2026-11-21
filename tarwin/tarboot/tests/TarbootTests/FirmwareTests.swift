import KCore
import Tarboot
import Testing

private struct EFIBytes: ByteSource {
  var data: [UInt8] = []
  func byteCount() -> UInt64 { UInt64(data.count) }
  func byteAt(_ offset: UInt64) -> UInt8 { data[Int(offset)] }
  mutating func descriptor(_ type: UInt32, _ base: UInt64, _ pages: UInt64, _ attributes: UInt64) {
    for field in [UInt64(type), base, 0, pages, attributes, 0xfefe_fefe] {
      for i in 0..<8 { data.append(UInt8(truncatingIfNeeded: field >> (8 * i))) }
    }
  }
}

@Test func firmwareHandoff() {
  var map = EFIBytes()
  map.descriptor(7, 0x12000, 1, 8)
  map.descriptor(3, 0x2000, 1, 8)
  map.descriptor(11, 0x40000, 4, 1 << 63)
  map.descriptor(1, 0x8000, 2, 0)
  map.descriptor(5, 0x60000, 1, 1 << 63)
  var regions = [FirmwareRegion](repeating: .empty, count: 5)
  regions.withUnsafeMutableBufferPointer { buf in
    #expect(stageFirmwareMap(map, stride: 40, version: 1, into: &buf) == nil)
    #expect(stageFirmwareMap(map, stride: 48, version: 2, into: &buf) == nil)
    #expect(stageFirmwareMap(map, stride: 48, version: 1, into: &buf) == 5)
    #expect(buf.map(\.base) == [0x2000, 0x8000, 0x12000, 0x40000, 0x60000])
    #expect(buf.map { $0.bootMapKind(afterExit: false) } == [1, 1, 0, 1, 2])
    #expect(buf.map { $0.bootMapKind(afterExit: true) } == [0, 1, 0, 1, 2])
    var short = UnsafeMutableBufferPointer(rebasing: buf.prefix(4))
    #expect(stageFirmwareMap(map, stride: 48, version: 1, into: &short) == nil)
    for (base, pages): (UInt64, UInt64) in [
      (0x1001, 1), (0x1000, 0), (0x1000, 2), (0xffff_ffff_ffff_f000, 1),
    ] {
      var bad = EFIBytes()
      bad.descriptor(7, 0x2000, 2, 0)
      bad.descriptor(7, base, pages, 0)
      #expect(stageFirmwareMap(bad, stride: 48, version: 1, into: &buf) == nil)
    }
  }
}

@Test func nonOrdinaryMemoryNeverBecomesFreeAtFirmwareExit() {
  let flags: [UInt64] = [0, 1, 8 | 0x1000, 8 | 0x2000, 8 | 0x8000,
                         8 | 0x20000, 8 | 0x40000, 8 | (1 << 63)]
  for type: UInt32 in [3, 4, 7] {
    for attr in flags {
      var map = EFIBytes()
      map.descriptor(type, 0x4000, 1, attr)
      var region = FirmwareRegion.empty
      withUnsafeMutablePointer(to: &region) { p in
        var out = UnsafeMutableBufferPointer(start: p, count: 1)
        #expect(stageFirmwareMap(map, stride: 48, version: 1, into: &out) == 1)
        #expect(out[0].bootMapKind(afterExit: false) == 1)
        #expect(out[0].bootMapKind(afterExit: true) == 1)
      }
    }
  }
}
