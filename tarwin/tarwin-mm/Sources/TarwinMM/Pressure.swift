// Resource accounting saturates rather than wrapping below the limit.
// The caller takes a consistent snapshot under the job accounting lock.
func addCharge(_ a: UInt64, b: UInt64) -> UInt64 {
  if b > UInt64(0xffff_ffff_ffff_ffff) - a { return 0xffff_ffff_ffff_ffff }
  return a + b
}

public func footprint(
  _ residentPrivate: UInt64, compressedStored: UInt64, gpu: UInt64, kernel: UInt64
) -> UInt64 {
  return addCharge(addCharge(residentPrivate, b: compressedStored), b: addCharge(gpu, b: kernel))
}

// Band 0 = system-critical; 1 foreground, 2 visible, 3 audio/media,
// 4 background, 5 suspended, 6 cached. koid zero denotes no candidate.
public struct PressureCandidate {
  public internal(set) var koid: UInt64
  public internal(set) var band: UInt8
  public internal(set) var bytes: UInt64

  public init(koid: UInt64, band: UInt8, bytes: UInt64) {
    self.koid = koid
    self.band = band
    self.bytes = bytes
  }
}

public func noCandidate() -> PressureCandidate {
  return PressureCandidate(koid: 0, band: 0, bytes: 0)
}

// Run only after reclamation fails. A caller finding no eligible process
// diagnoses the configuration instead of killing a system-critical service.
public func selectVictim(_ best: PressureCandidate, next: PressureCandidate) -> PressureCandidate {
  if next.koid == 0 || next.band == 0 || next.band > 6 { return best }
  if best.koid == 0 || next.band > best.band { return next }
  if next.band == best.band
    && (next.bytes > best.bytes || (next.bytes == best.bytes && next.koid < best.koid))
  {
    return next
  }
  return best
}

public func exceedsFootprint(_ band: UInt8, bytes: UInt64, limit: UInt64) -> Bool {
  return band > 0 && band <= 6 && bytes > limit
}

// Object-locked purge epoch. noteDiscard is called only after actually
// unmapping and releasing an unpinned volatile page. Multiple losses in
// an epoch cause one "contents lost" at the next nonvolatile transition.
public struct PurgeState {
  public internal(set) var isVolatile: Bool
  public internal(set) var lost: Bool

  public init(isVolatile: Bool, lost: Bool) {
    self.isVolatile = isVolatile
    self.lost = lost
  }
}

public func makeVolatile(_ state: inout PurgeState) { state.isVolatile = true }
public func mayDiscard(_ state: PurgeState, pinCount: UInt64) -> Bool {
  return state.isVolatile && pinCount == 0
}
public func noteDiscard(_ state: inout PurgeState) { if state.isVolatile { state.lost = true } }
public func makeNonvolatile(_ state: inout PurgeState) -> Bool {
  let survived = !state.lost
  state.isVolatile = false
  state.lost = false
  return survived
}
