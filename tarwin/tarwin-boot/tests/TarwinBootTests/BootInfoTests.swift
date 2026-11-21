import TarwinBoot
import Testing

@Test func bootInfoTests() {
  var info = emptyBootInfo()
  info.year = 26
  info.month = 11
  info.week = 1
  info.mapAddress = 0x10000
  info.mapCount = 2
  info.rsdp = 0x3000
  info.bootSet = 0x100000
  info.bootSetSize = 8000
  info.entropy0 = 0x0706_0504_0302_0100
  info.entropy7 = 0x3f3e_3d3c_3b3a_3938
  info.slot = 1
  info.security = 1
  info.kernelVirtual = 0xffff_8000_0000_4000
  info.panicRecord = 0x20000
  #expect(validBootInfo(info))
  #expect(!bootBlockFits(1, capacity: 4096))
  #expect(!bootBlockFits(4096, capacity: 4095))
  #expect(bootInfoByte(info, offset: 0) == 0x54)
  #expect(bootInfoByte(info, offset: 1) == 0x42)
  #expect(bootInfoByte(info, offset: 2) == 0x49)
  #expect(bootInfoByte(info, offset: 3) == 0x42)
  #expect(bootInfoByte(info, offset: 9) == 16)
  #expect(bootInfoByte(info, offset: 103) == 7)
  #expect(bootInfoByte(info, offset: 159) == 63)
  #expect(bootInfoByte(info, offset: 210) == 2)
  var state = beginBootInfo(0x2000, capacity: 4096)
  var corrupt = beginBootInfo(0x2000, capacity: 4096)
  var i: UInt64 = 0
  while i < 4096 {
    #expect(!completeBootInfo(state))
    let byte = bootInfoByte(info, offset: i)
    #expect(acceptBootByte(&state, byte: byte))
    let ok = acceptBootByte(&corrupt, byte: i == 178 ? UInt8(1) : byte)
    #expect(!(i >= 183 && ok))
    i += 1
  }
  #expect(completeBootInfo(state))
  #expect(!completeBootInfo(corrupt))
  #expect(state.decoded?.kernelVirtual == info.kernelVirtual)
  #expect(corrupt.decoded == nil)
  #expect(!acceptBootByte(&state, byte: 0))
  #expect(!completeBootInfo(state))
  info.mapCount = 0xffff_ffff_ffff_ffff
  #expect(!validBootInfo(info))
  var map = beginMemoryMap(2, available: 64)
  #expect(!completeMemoryMap(map))
  #expect(acceptRegion(&map, base: 0, length: 0x1000, typeAndAttributes: 1, reserved: 0))
  #expect(acceptRegion(&map, base: 0x1000, length: 0x4000, typeAndAttributes: 0, reserved: 0))
  #expect(completeMemoryMap(map))
  var bad = beginMemoryMap(2, available: 64)
  #expect(acceptRegion(&bad, base: 0, length: 2, typeAndAttributes: 0, reserved: 0))
  #expect(!acceptRegion(&bad, base: 1, length: 1, typeAndAttributes: 0, reserved: 0))
  #expect(!completeMemoryMap(bad))
}
