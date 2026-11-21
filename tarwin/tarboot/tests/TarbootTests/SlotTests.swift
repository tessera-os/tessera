import Tarboot
import Testing

@Test func slotTests() {
  #expect(archiveTests())
  var a = SlotState(tries: 3, confirmed: false)
  var b = SlotState(tries: 0, confirmed: true)
  while a.tries != 0 {
    let picked = chooseSlot(0, a: a, b: b, recover: false)
    #expect(picked.slot == 0)
    #expect(picked.persist)
    #expect(picked.remaining == a.tries - 1)
    a.tries = picked.remaining
  }
  let fallback = chooseSlot(0, a: a, b: b, recover: false)
  #expect(fallback.slot == 1)
  #expect(fallback.persist)
  #expect(fallback.remaining == 0)
  #expect(!chooseSlot(1, a: a, b: b, recover: false).persist)
  #expect(chooseSlot(1, a: a, b: b, recover: true).slot == 2)
  b.confirmed = false
  #expect(chooseSlot(1, a: a, b: b, recover: false).slot == 2)
  a.tries = 4
  #expect(chooseSlot(0, a: a, b: b, recover: false).slot == 2)
  #expect(bootSetError(false, version: 99, floor: 1) == 1)
  #expect(bootSetError(true, version: 0, floor: 1) == 2)
  #expect(bootSetError(true, version: 1, floor: 1) == 0)
  #expect(confirmedFloor(1, version: 2, authenticated: true, confirmed: false) == 1)
  #expect(confirmedFloor(2, version: 1, authenticated: true, confirmed: true) == 2)
  #expect(confirmedFloor(2, version: 3, authenticated: true, confirmed: true) == 3)
}
