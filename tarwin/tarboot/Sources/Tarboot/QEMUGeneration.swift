public enum QEMUGenerationDevice {
  case unavailable, malformed
  /// The catalogue advertised both blobs, not a trusted current generation.
  case advertised(addressKey: UInt16, guidKey: UInt16)
}

/// Inventory only. Never use the GUID file's initial bytes as a restore
/// witness: the running guest needs the hypervisor-updated location.
public func qemuGenerationDevice<R: QEMUConfigReader>(_ r: inout R) -> QEMUGenerationDevice {
  var address: UInt16?, guid: UInt16?
  guard inventoryQEMUFiles(&r, visit: { key, size, file in
    if matchesQEMUName(file, "etc/vmgenid_addr") {
      guard address == nil, size == 8 else { return false }
      address = key
    } else if matchesQEMUName(file, "etc/vmgenid_guid") {
      guard guid == nil, size == 4096 else { return false }
      guid = key
    }
    return true
  }) else { return .malformed }
  if address == nil && guid == nil { return .unavailable }
  guard let address, let guid else { return .malformed }
  return .advertised(addressKey: address, guidKey: guid)
}
