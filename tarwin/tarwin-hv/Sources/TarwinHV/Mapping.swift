public enum ExtentPhase { case empty, mapped, detached, invalidated }
public struct GuestExtent {
  public internal(set) var phase: ExtentPhase = .empty
  public internal(set) var start: UInt64 = 0
  public internal(set) var size: UInt64 = 0
  public internal(set) var pin: UInt64 = 0

  public init() {}

  // Under the VM address-space writer lock, with a reserved nonoverlapping interval.
  // install is all-or-nothing; pin/unpin own the backing object across shootdown.
  public mutating func map(
    _ guest: UInt64, _ offset: UInt64, _ length: UInt64, _ guestLimit: UInt64,
    _ objectSize: UInt64, _ page: UInt64, _ permissions: UInt64, _ rights: UInt64,
    _ pinMemory: (UInt64, UInt64) -> UInt64, _ install: (UInt64, UInt64, UInt64, UInt64) -> Bool,
    _ unpin: (UInt64) -> Void
  ) -> Bool {
    if phase != .empty
      || !validMapping(guest, offset, length, guestLimit, objectSize, page, permissions, rights)
    {
      return false
    }
    let token = pinMemory(offset, length)
    if token == 0 { return false }
    if !install(guest, length, token, permissions) {
      unpin(token)
      return false
    }
    start = guest
    size = length
    pin = token
    phase = .mapped
    return true
  }

  // Failed shootdown leaves the interval quarantined; a retry never re-detaches.
  public mutating func retire(
    _ detach: (UInt64, UInt64) -> Bool,
    _ shootdown: (UInt64, UInt64) -> Bool, _ unpin: (UInt64) -> Void
  ) -> Bool {
    if phase == .empty { return false }
    if phase == .mapped {
      if !detach(start, size) { return false }
      phase = .detached
    }
    if phase == .detached {
      if !shootdown(start, size) { return false }
      phase = .invalidated
    }
    unpin(pin)
    pin = 0
    size = 0
    phase = .empty
    return true
  }
}
