import KCore

/// The table identifies a remapping unit, not an isolation group or slot.
/// Its register window must also be reserved by the trusted platform memory map.
public struct FirmwareVtd: Equatable {
  public let registers: DeviceRange
  public let addressBits: UInt8
}

/// Conservative legacy subset: a single DRHD and direct endpoint scopes (or
/// INCLUDE_PCI_ALL). Reject RMRR and extra/unknown structures rather than
/// drive a device without the firmware's complete translation constraints.
/// The source must be the complete immutable table selected by the ACPI root.
public func firmwareVtd<S: ByteSource>(
  _ table: S, segment: UInt16, requester: UInt16,
  reservedRegisters: (DeviceRange) -> Bool
) -> FirmwareVtd? {
  let length = table.byteCount()
  guard length >= 64, length <= 65536 else { return nil }
  func le(_ at: UInt64, _ size: UInt64) -> UInt64 {
    var value: UInt64 = 0
    for i in 0..<size { value |= UInt64(table.byteAt(at + i)) << (8 * i) }
    return value
  }
  guard le(0, 4) == 0x5241_4d44, le(4, 4) == length, table.byteAt(8) == 1,
    (38...51).contains(table.byteAt(36)), table.byteAt(37) == 0
  else { return nil }
  var checksum: UInt8 = 0
  for i in 0..<length { checksum &+= table.byteAt(i) }
  guard checksum == 0 else { return nil }
  for i: UInt64 in 38..<48 where table.byteAt(i) != 0 { return nil }
  guard le(48, 2) == 0, le(50, 2) == length - 48, le(52, 2) <= 1,
    le(54, 2) == UInt64(segment)
  else { return nil }
  let all = table.byteAt(52) == 1
  let bits = table.byteAt(36) + 1
  let base = le(56, 8)
  guard base != 0, base & 4095 == 0, base >> bits == 0 else { return nil }
  let registers = DeviceRange(base: base, length: 4096)
  var at: UInt64 = 64
  var matched = false
  var excluded = false
  while at < length {
    guard length - at >= 8, table.byteAt(at + 1) == 8,
      le(at + 2, 2) == 0, table.byteAt(at + 6) < 32, table.byteAt(at + 7) < 8
    else { return nil }
    let id =
      UInt16(table.byteAt(at + 5)) << 8 | UInt16(table.byteAt(at + 6)) << 3
      | UInt16(table.byteAt(at + 7))
    switch table.byteAt(at) {
    case 1:
      guard !all, table.byteAt(at + 4) == 0 else { return nil }
      if requester == id {
        guard !matched else { return nil }
        matched = true
      }
    case 3, 4:
      if requester == id { excluded = true }
    default: return nil
    }
    at += 8
  }
  guard !excluded, all || matched, reservedRegisters(registers) else { return nil }
  return FirmwareVtd(registers: registers, addressBits: bits)
}
