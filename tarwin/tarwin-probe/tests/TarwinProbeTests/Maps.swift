import Testing

@testable import TarwinProbe

@Test
func perCpuMapCannotAliasAnotherCpuOrOverflowQuota() {
  let map = ProbeMapShape(kind: .perCpu, capacity: 10, elementSize: 8)
  #expect(validMap(map, 4, 320))
  #expect(!validMap(map, 4, 319))
  #expect(mapOffset(map, 2, 4, 9, 320) == 232)
  #expect(mapOffset(map, 4, 4, 0, 320) == 0xffff_ffff_ffff_ffff)
  #expect(mapOffset(map, 1, 4, 10, 320) == 0xffff_ffff_ffff_ffff)
  #expect(
    !validMap(
      ProbeMapShape(kind: .hashTable, capacity: 16_777_217, elementSize: 1), 1,
      0xffff_ffff_ffff_ffff))
}
