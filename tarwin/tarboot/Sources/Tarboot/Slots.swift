// The caller authenticates both slot records and persists a changed selection
// atomically before entry. Recovery is independently verified, never a shell.
public struct SlotState {
  public var tries: UInt8
  public var confirmed: Bool

  public init(tries: UInt8, confirmed: Bool) {
    self.tries = tries
    self.confirmed = confirmed
  }
}

public struct BootSelection {
  public internal(set) var slot: UInt8
  public internal(set) var remaining: UInt8
  public internal(set) var persist: Bool
}

func hasAttempt(_ state: SlotState) -> Bool {
  return state.tries <= 3 && (state.confirmed || state.tries != 0)
}

public func chooseSlot(_ active: UInt8, a: SlotState, b: SlotState, recover: Bool) -> BootSelection
{
  if recover || active > 1 || a.tries > 3 || b.tries > 3 {
    return BootSelection(slot: 2, remaining: 0, persist: false)
  }
  var selected = active
  if (selected == 0 && !hasAttempt(a)) || (selected == 1 && !hasAttempt(b)) {
    selected = UInt8(1) - selected
  }
  let tries = selected == 0 ? a.tries : b.tries
  let confirmed = selected == 0 ? a.confirmed : b.confirmed
  if confirmed {
    return BootSelection(slot: selected, remaining: tries, persist: selected != active)
  }
  if tries == 0 { return BootSelection(slot: 2, remaining: 0, persist: false) }
  return BootSelection(slot: selected, remaining: tries - 1, persist: true)
}

// Only a verified image supplies a trustworthy security version. Apply this
// floor to recovery and soft reboots as well as normal slot selection.
public func bootSetError(_ authenticated: Bool, version: UInt64, floor: UInt64) -> UInt32 {
  if !authenticated { return 1 }  // TARWIN-B0001
  if version < floor { return 2 }  // TARWIN-B0002
  return 0
}

public func confirmedFloor(_ current: UInt64, version: UInt64, authenticated: Bool, confirmed: Bool)
  -> UInt64
{
  if authenticated && confirmed && version > current { return version }
  return current
}
