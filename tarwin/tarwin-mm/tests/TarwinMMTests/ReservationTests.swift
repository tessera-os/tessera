import TarwinMM
import Testing

@Test func ownedArenaAlignment() {
  for granule: UInt64 in [4096, 16384] {
    let span = granule * 64
    #expect(arenaFromReservation(base: 4096, length: 2 * span - 4097, pageSize: granule) == nil)
    guard var arena = arenaFromReservation(base: 4096, length: 2 * span - 4096, pageSize: granule)
    else {
      Issue.record("exact fit rejected")
      return
    }
    let all = takePages(&arena, order: 6)
    #expect(all.ok && all.address == span)
    #expect(takePages(&arena, order: 0).ok == false)
    #expect(givePages(&arena, address: all.address, order: 6))
    #expect(arenaFromReservation(base: .max - span, length: span + 1, pageSize: granule) == nil)
  }
  #expect(arenaFromReservation(base: 0, length: .max, pageSize: 4096) == nil)
  #expect(arenaFromReservation(base: 4096, length: .max - 4096, pageSize: 8192) == nil)
}
