/// Serialized read-only fw_cfg transactions. Implementations translate the
/// selector to the bus byte order; reads advance by exactly one byte.
public protocol QEMUConfigReader {
  mutating func select(_ key: UInt16)
  mutating func readByte() -> UInt8
}

public enum QEMUGenerationDevice {
  case unavailable, malformed
  /// The catalogue advertised both blobs, not a trusted current generation.
  case advertised(addressKey: UInt16, guidKey: UInt16)
}

/// Inventory only. Never use the GUID file's initial bytes as a restore
/// witness: the running guest needs the hypervisor-updated location.
public func qemuGenerationDevice<R: QEMUConfigReader>(_ r: inout R) -> QEMUGenerationDevice {
  func word(_ n: Int) -> UInt32 {
    var v: UInt32 = 0
    for _ in 0..<n { v = v << 8 | UInt32(r.readByte()) }
    return v
  }
  r.select(0)
  guard word(4) == 0x5145_4d55 else { return .malformed } // "QEMU"
  r.select(0x19)
  let count = word(4)
  guard count > 0, count <= 4096 else { return .malformed }
  var address: UInt16?, guid: UInt16?
  let addrName: StaticString = "etc/vmgenid_addr"
  let guidName: StaticString = "etc/vmgenid_guid"
  for _ in 0..<count {
    let size = word(4), key = UInt16(word(2))
    guard word(2) == 0, key >= 0x20, key < 0x4000 else { return .malformed }
    var isAddr = true, isGuid = true, ended = false
    for i in 0..<56 {
      let b = r.readByte()
      guard i != 0 || b != 0 else { return .malformed }
      if ended { continue }
      if b == 0 {
        ended = true
        isAddr = isAddr && i == addrName.utf8CodeUnitCount
        isGuid = isGuid && i == guidName.utf8CodeUnitCount
      } else {
        isAddr = isAddr && i < addrName.utf8CodeUnitCount && b == addrName.utf8Start[i]
        isGuid = isGuid && i < guidName.utf8CodeUnitCount && b == guidName.utf8Start[i]
      }
    }
    guard ended else { return .malformed }
    if isAddr {
      guard address == nil, size == 8 else { return .malformed }
      address = key
    } else if isGuid {
      guard guid == nil, size == 4096 else { return .malformed }
      guid = key
    }
  }
  if address == nil && guid == nil { return .unavailable }
  guard let address, let guid, address != guid else { return .malformed }
  return .advertised(addressKey: address, guidKey: guid)
}
