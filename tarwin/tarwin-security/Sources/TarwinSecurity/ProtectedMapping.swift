public enum PageRole {
  case anonymous
  case signedImageCode
  case sealedCompileCode
  case kernelCode
  case kernelData
  case pageTable
  case protectedRecord
  case guestRam
  case deviceMemory
}

public struct MappingRights {
  public let writable: Bool
  public let executable: Bool
  public let user: Bool

  public init(writable: Bool, executable: Bool, user: Bool) {
    self.writable = writable
    self.executable = executable
    self.user = user
  }
}

// The gated writer gets role from protected physical-page metadata, never
// from the requested PTE. This check covers normal mappings, not the
// per-CPU edit alias itself, which is private to the architecture primitive.
public func mappingAllowed(_ role: PageRole, _ wanted: MappingRights) -> Bool {
  if wanted.writable && wanted.executable { return false }
  return switch role {
  case .kernelCode: !wanted.user && !wanted.writable
  case .kernelData: !wanted.user && !wanted.executable
  case .pageTable: !wanted.user && !wanted.executable && !wanted.writable
  case .protectedRecord: !wanted.user && !wanted.executable && !wanted.writable
  case .signedImageCode: !wanted.writable && (!wanted.executable || wanted.user)
  case .sealedCompileCode: !wanted.writable && (!wanted.executable || wanted.user)
  case .deviceMemory: !wanted.executable
  case .guestRam: !wanted.executable
  case .anonymous: !wanted.executable
  }
}

// Used by the gated writer for a rights update, not for minting a fresh
// boot resource. The reference and resource kind remain immutable.
public func protectedRightsMayNarrow(_ old: UInt64, _ requested: UInt64) -> Bool {
  return (old & requested) == requested
}
