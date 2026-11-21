public enum ExtentPhase { case empty, mapped, detached, invalidated, quarantinedMapped }
public struct GuestExtent {
  public internal(set) var phase: ExtentPhase = .empty
  public internal(set) var start: UInt64 = 0
  public internal(set) var size: UInt64 = 0
  public internal(set) var pin: UInt64 = 0
  public private(set) var guestPermissions: UInt64 = 0
  public private(set) var writeTrapped = false

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
    guestPermissions = permissions
    writeTrapped = false
    phase = .mapped
    return true
  }

  // The original guest grant, not just the backing object's rights, must allow
  // RW/NX. Stop every walker and exclude DMA throughout this transition. Both
  // invalidations must finish on all relevant CPUs before the VM can resume.
  public mutating func trapWrites(
    _ enabled: Bool, detach: (UInt64, UInt64) -> Bool, invalidate: (UInt64, UInt64) -> Bool,
    install: (UInt64, UInt64, UInt64, UInt64) -> Bool
  ) -> Bool {
    guard phase == .mapped, guestPermissions == 3 else { return false }
    if enabled == writeTrapped { return true }
    guard detach(start, size) else { return false }
    phase = .detached
    guard invalidate(start, size), install(start, size, pin, enabled ? 1 : 3) else { return false }
    phase = .quarantinedMapped
    guard invalidate(start, size) else { return false }
    phase = .mapped
    writeTrapped = enabled
    return true
  }

  // Failed shootdown leaves the interval quarantined; a retry never re-detaches.
  public mutating func retire(
    _ detach: (UInt64, UInt64) -> Bool,
    _ shootdown: (UInt64, UInt64) -> Bool, _ unpin: (UInt64) -> Void
  ) -> Bool {
    if phase == .empty { return false }
    if phase == .mapped || phase == .quarantinedMapped {
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
    guestPermissions = 0
    writeTrapped = false
    phase = .empty
    return true
  }
}
