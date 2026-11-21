import Testing

@testable import TarwinHV

func pin(_ offset: UInt64, _ length: UInt64) -> UInt64 { return 7 }
func installPage(_ g: UInt64, _ n: UInt64, _ token: UInt64, _ rights: UInt64) -> Bool {
  return token == 7
}
func noRelease(_ token: UInt64) {}
func yesRange(_ start: UInt64, _ n: UInt64) -> Bool { return true }
func noRange(_ start: UInt64, _ n: UInt64) -> Bool { return false }
func reserve(_ vm: UInt64, _ slot: UInt64) -> UInt64 { return 9 }
func okStep(_ token: UInt64) -> Bool { return token == 9 }
func failStep(_ token: UInt64) -> Bool { return false }

@Test
func quarantineUntilEveryTranslationIsInvalidated() {
  var space = GuestExtent()
  #expect(space.map(0, 0, 4096, 4096, 4096, 4096, 3, 3, pin, installPage, noRelease) == true)
  #expect(space.retire(yesRange, noRange, noRelease) == false)
  #expect(space.pin == 7)
  #expect(space.map(0, 0, 4096, 4096, 4096, 4096, 3, 3, pin, installPage, noRelease) == false)
  #expect(space.retire(noRange, yesRange, noRelease) == true)
  #expect(space.pin == 0)
  var slot = Assignment()
  #expect(
    slot.assign(1, 2, false, true, true, true, true, reserve, okStep, okStep, failStep, okStep)
      == HvError.featureUnavailable)
  #expect(slot.state == SlotState.interrupts)
  #expect(slot.release(okStep, failStep, okStep, failStep, okStep) == false)
  #expect(slot.state == SlotState.draining)
  #expect(slot.translations)
  #expect(!slot.interrupts)
  #expect(slot.release(failStep, failStep, failStep, okStep, okStep) == true)
  #expect(slot.state == SlotState.free)
}

nonisolated(unsafe) private var words: [UInt64] = [0, 0]
func word(_ i: UInt64) -> UInt64 { return words[Int(i)] }
func setWord(_ i: UInt64, _ n: UInt64) { words[Int(i)] = n }
func wantThree(_ i: UInt64, _ bits: UInt64) -> Bool { return i == 1 && bits == 3 }
@Test
func dirtyLogClipsTailAndRetainsOnFailedDelivery() {
  var log = DirtyPages(first: 4, pages: 66)
  #expect(log.mark(69, 2, word, setWord) == false)
  #expect(log.mark(67, 3, word, setWord) == true)
  #expect(word(0) == 0x8000_0000_0000_0000)
  #expect(log.collectWord(1, word, noRange, setWord, wantThree) == false)
  #expect(word(1) == 3)
  #expect(log.collectWord(1, word, yesRange, setWord, wantThree) == true)
  #expect(word(1) == 0)
}
