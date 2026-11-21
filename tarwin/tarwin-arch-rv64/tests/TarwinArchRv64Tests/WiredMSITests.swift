import TarwinArchRv64
import Testing

@Test func routesOnlyAnUnusedSupervisorSource() throws {
  let route = try #require(RvWiredMSI(source: 11, sources: 96, hartIndex: 3, identity: 65, identities: 255))
  #expect(route.enableSelect == 0xc2 && route.enableBit == 2)
  var regs: [UInt32: UInt32] = [0: 0x8000_0004]
  var writes: [(UInt32, UInt32)] = []
  func read(_ at: UInt32) -> UInt32 { regs[at] ?? 0 }
  func write(_ at: UInt32, _ value: UInt32) {
    writes.append((at, value))
    regs[at] = at == 0 ? 0x8000_0000 | value : value
  }
  for (offset, value): (UInt32, UInt32) in [(0, 0x8000_0000), (0, 0x8000_0104),
    (11 * 4, 1 << 10), (0x1e0c, 1)] {
    let saved = regs
    regs[offset] = value
    #expect(route.installMasked(read: read, write: write) == false)
    #expect(writes.isEmpty)
    regs = saved
  }
  #expect(route.installMasked(read: read, write: write) == true)
  let destination: UInt32 = 3 << 18 | 65
  #expect(regs[0x302c] == destination)
  route.unmask(write: write)
  route.mask(write: write)
  #expect(writes.map(\.0) == [0x2c, 0x302c, 0, 0x1cdc, 0x1edc, 0x1fdc])
  #expect(writes.suffix(3).allSatisfy { $0.1 == 11 })
}

@Test func rejectsOutOfRangeRoutes() {
  for (source, sources, hart, id, ids): (UInt32, UInt32, UInt32, UInt32, UInt32) in [
    (0, 96, 0, 1, 63), (97, 96, 0, 1, 63), (7, 1024, 0, 1, 63),
    (1, 96, 16384, 1, 63), (1, 96, 0, 0, 63), (1, 96, 0, 64, 63),
    (1, 96, 0, 3, 64), (1, 96, 0, 3, 4095)] {
    #expect(RvWiredMSI(source: source, sources: sources, hartIndex: hart, identity: id, identities: ids) == nil)
  }
}
