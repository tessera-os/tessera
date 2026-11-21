import Testing

@testable import TVMM

func installDax(_ list: [DaxExtent]) -> Bool { return true }
func failDax(_ list: [DaxExtent]) -> Bool { return false }
func installIo(_ list: [GuestTranslation]) -> Bool { return true }
@Test
func daxReplaceSplitsOnlyTheGrantedIntervalAndRollsBackFailure() {
  var w = DaxWindow(size: 16384, align: 4096, extentLimit: 3, epoch: 9)
  #expect(w.replace(9, 0, 16384, 4, 4096, 20480, false, false, installDax) == true)
  #expect(w.replace(8, 4096, 4096, 5, 0, 4096, false, false, installDax) == false)
  #expect(w.replace(9, 4096, 4096, 5, 0, 4096, true, false, installDax) == false)
  #expect(w.replace(9, 4096, 4096, 5, 0, 4096, true, true, failDax) == false)
  #expect(w.live.count == 1)
  #expect(w.replace(9, 4096, 4096, 5, 0, 4096, true, true, installDax) == true)
  #expect(w.live.count == 3)
  #expect(w.live[1].offset == 12288)
  #expect(w.live[2].file == 5)
  #expect(w.replace(9, 0, 16384, 0, 0, 0, false, false, installDax) == true)
  #expect(w.live.count == 0)
}
@Test
func iommuUnmapCannotPartiallyDropNestedTranslation() {
  var d = GuestDomain(
    id: 1, pageSize: 4096, maxMappings: 2, ram: GuestAperture(base: 0, length: 8192))
  var map: [UInt8] = []
  for _ in 0..<36 { map.append(0) }
  map[0] = 3
  map[4] = 1
  map[16] = 255
  map[17] = 31
  map[32] = 3
  #expect(d.command(map, installIo) == 0)
  #expect(d.command(map, installIo) != 0)
  var unmap: [UInt8] = []
  for n in 0..<28 { unmap.append(map[n]) }
  unmap[0] = 4
  unmap[17] = 15
  #expect(d.command(unmap, installIo) != 0)
  #expect(d.maps.count == 1)
  unmap[17] = 31
  #expect(d.command(unmap, installIo) == 0)
  #expect(d.maps.count == 0)
}
