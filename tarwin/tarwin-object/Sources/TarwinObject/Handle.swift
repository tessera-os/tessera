public enum HandleLayout {
  public static let maximumSlots: UInt32 = 1_048_576
  public static let defaultSlots: UInt32 = 65536
  public static let indexMask: UInt64 = 0xfffff
  public static let lastGeneration: UInt64 = 0xf_ffff_ffff
}

public func handleIndex(_ value: UInt64) -> UInt32 {
  return UInt32(value & HandleLayout.indexMask)
}

public func objectKindAllocated(_ kind: UInt32) -> Bool {
  return (kind >= TarwinKind.port && kind <= TarwinKind.presence)
    || (kind >= TarwinKind.interrupt && kind <= TarwinKind.fence)
}

public enum HandleCheck {
  case allowed
  case invalidHandle
  case wrongType
  case accessDenied
}

// Slot mutations require the table writer lock. Lookups validate a single
// immutable published snapshot within the reader epoch; the caller pins its
// object before leaving the epoch. This value is not an atomic publication.
public struct HandleSlot {
  public internal(set) var generation: UInt64
  public internal(set) var koid: UInt64
  public internal(set) var rights: UInt64
  public internal(set) var kind: UInt32

  public func name(_ salt: UInt8, _ index: UInt32) -> UInt64 {
    if index >= HandleLayout.maximumSlots || koid == 0 { return 0 }
    if generation == 0 || generation > HandleLayout.lastGeneration { return 0 }
    return (UInt64(salt) << 56) | (generation << 20) | UInt64(index)
  }

  public mutating func install(
    _ newKoid: UInt64, _ newKind: UInt32, _ grant: UInt64, _ ceiling: UInt64
  ) -> Bool {
    if koid != 0 || generation == 0 || generation > HandleLayout.lastGeneration { return false }
    if newKoid == 0 || !objectKindAllocated(newKind) { return false }
    if (grant & ceiling) != grant || grant >> 32 != 0 { return false }
    if newKind == TarwinKind.presence && (grant & 3) != 0 { return false }
    koid = newKoid
    kind = newKind
    rights = grant
    return true
  }

  public func check(
    _ value: UInt64, _ salt: UInt8, _ index: UInt32, _ expected: UInt32, _ need: UInt64
  ) -> HandleCheck {
    if value == 0 || value != name(salt, index) { return .invalidHandle }
    if expected != 0 && expected != kind { return .wrongType }
    if (rights & need) != need { return .accessDenied }
    return .allowed
  }

  // Returns the released object ID, to be dropped after publishing the
  // invalidation. The terminal generation retires rather than reviving a name.
  public mutating func revoke() -> UInt64 {
    let old = koid
    if old != 0 {
      koid = 0
      kind = 0
      rights = 0
      if generation == HandleLayout.lastGeneration { generation = 0 } else { generation += 1 }
    }
    return old
  }
}

public func unusedHandleSlot() -> HandleSlot {
  return HandleSlot(generation: 1, koid: 0, rights: 0, kind: 0)
}

// RIGHTS_SAME is a sentinel for duplicate only; replacement never expands
// rights and does not require Duplicate.
public func handleMayDerive(_ source: UInt64, _ requested: UInt64, _ duplicate: Bool) -> Bool {
  if duplicate && (source & 1) == 0 { return false }
  if requested == 0xffff_ffff_ffff_ffff { return duplicate }
  return (source & requested) == requested
}
