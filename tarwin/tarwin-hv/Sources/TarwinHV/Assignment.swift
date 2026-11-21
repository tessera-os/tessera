// One lease per DeviceSlot under its exclusive owner lock. Backends operate only
// on that slot and VM; a failed install publishes nothing. Stop/drain includes bus
// mastering and posted writes. A failed cleanup leaves the slot unavailable.
public enum SlotState { case free, owned, dma, interrupts, mapped, active, draining }
public struct Assignment {
  public internal(set) var state: SlotState = .free
  public internal(set) var lease: UInt64 = 0
  public internal(set) var translations: Bool = false
  public internal(set) var interrupts: Bool = false
  public internal(set) var apertures: Bool = false

  public init() {}

  public mutating func assign(
    _ vm: UInt64, _ slot: UInt64, _ permit: Bool, _ slotGrant: Bool,
    _ nested: Bool, _ posted: Bool, _ mmio: Bool,
    _ reserveStopped: (UInt64, UInt64) -> UInt64, _ installNested: (UInt64) -> Bool,
    _ routePosted: (UInt64) -> Bool, _ mapIsolated: (UInt64) -> Bool,
    _ enable: (UInt64) -> Bool
  ) -> HvError {
    let admission = admitAssignment(permit, slotGrant, nested, posted, mmio)
    if admission != HvError.ok { return admission }
    if vm == 0 || slot == 0 { return .invalid }
    if state != .free { return .busy }
    lease = reserveStopped(vm, slot)
    if lease == 0 { return .busy }
    state = .owned
    if !installNested(lease) { return .featureUnavailable }
    translations = true
    state = .dma
    if !routePosted(lease) { return .featureUnavailable }
    interrupts = true
    state = .interrupts
    if !mapIsolated(lease) { return .featureUnavailable }
    apertures = true
    state = .mapped
    if !enable(lease) { return .featureUnavailable }
    state = .active
    return .ok
  }

  public mutating func release(
    _ stopAndDrain: (UInt64) -> Bool,
    _ removeMmioAndShootdown: (UInt64) -> Bool,
    _ unrouteAndDrain: (UInt64) -> Bool,
    _ detachAndInvalidateDma: (UInt64) -> Bool,
    _ resetAndReturn: (UInt64) -> Bool
  ) -> Bool {
    if state == .free { return false }
    if state != .draining {
      if !stopAndDrain(lease) { return false }
      state = .draining
    }
    if apertures {
      if !removeMmioAndShootdown(lease) { return false }
      apertures = false
    }
    if interrupts {
      if !unrouteAndDrain(lease) { return false }
      interrupts = false
    }
    if translations {
      if !detachAndInvalidateDma(lease) { return false }
      translations = false
    }
    if !resetAndReturn(lease) { return false }
    state = .free
    lease = 0
    return true
  }
}
