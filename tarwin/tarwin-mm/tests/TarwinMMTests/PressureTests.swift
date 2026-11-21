import TarwinMM

func pressureTests() -> Bool {
  if footprint(7, compressedStored: 8, gpu: 9, kernel: 10) != 34
    || footprint(0xffff_ffff_ffff_ffff, compressedStored: 0, gpu: 0, kernel: 1)
      != 0xffff_ffff_ffff_ffff
  {
    return false
  }
  var best = noCandidate()
  best = selectVictim(best, next: PressureCandidate(koid: 3, band: 0, bytes: 1000))
  if best.koid != 0 { return false }
  best = selectVictim(best, next: PressureCandidate(koid: 3, band: 2, bytes: 999))
  best = selectVictim(best, next: PressureCandidate(koid: 4, band: 6, bytes: 2))
  best = selectVictim(best, next: PressureCandidate(koid: 7, band: 6, bytes: 3))
  best = selectVictim(best, next: PressureCandidate(koid: 5, band: 6, bytes: 3))
  if best.koid != 5 || exceedsFootprint(0, bytes: 2, limit: 1)
    || !exceedsFootprint(6, bytes: 2, limit: 1)
  {
    return false
  }
  var purge = PurgeState(isVolatile: false, lost: false)
  if mayDiscard(purge, pinCount: 0) { return false }
  makeVolatile(&purge)
  if mayDiscard(purge, pinCount: 1) || !mayDiscard(purge, pinCount: 0) { return false }
  noteDiscard(&purge)
  makeVolatile(&purge)
  if makeNonvolatile(&purge) || mayDiscard(purge, pinCount: 0) { return false }
  makeVolatile(&purge)
  return makeNonvolatile(&purge)
}
