import KCore
import TarwinBoot

/// Physical addresses only. Consumers must preserve their backing in the boot
/// map until they finish using it; ACPI consumers must still validate each SDT.
public struct FirmwareTableLocations {
  public let rsdp: UInt64
  public let deviceTree: UInt64
  let finalEvents: UInt64
}

public struct InspectedFirmwareTables {
  public let rsdp: UInt64
  public let deviceTree: UInt64
  public let treeBytes: UInt64
}

private struct TableBytes: ByteSource {
  let data: UnsafeRawPointer
  let length: UInt64
  func byteCount() -> UInt64 { length }
  func byteAt(_ i: UInt64) -> UInt8 {
    // Bounded reads from firmware data in the boot CPU's physical identity map.
    precondition(i < length)
    return data.load(fromByteOffset: Int(i), as: UInt8.self)
  }
}

private func checksum<S: ByteSource>(_ bytes: S, count: UInt64) -> Bool {
  var sum: UInt8 = 0
  for i in 0..<count { sum &+= bytes.byteAt(i) }
  return sum == 0
}

func xsdtAddress<S: ByteSource>(_ bytes: S) -> UInt64? {
  guard bytes.byteCount() >= 36, little(bytes, at: 0, bytes: 8) == 0x2052_5450_2044_5352,
    bytes.byteAt(15) == 2, checksum(bytes, count: 20), little(bytes, at: 20, bytes: 4) == 36,
    checksum(bytes, count: 36), little(bytes, at: 33, bytes: 3) == 0
  else { return nil }
  let address = little(bytes, at: 24, bytes: 8)
  return address == 0 ? nil : address
}

func validXSDT<S: ByteSource>(_ bytes: S) -> Bool {
  guard bytes.byteCount() >= 36, little(bytes, at: 0, bytes: 4) == 0x5444_5358 else { return false }
  let n = little(bytes, at: 4, bytes: 4)
  guard n >= 44, n <= bytes.byteCount(), (n - 36) % 8 == 0, checksum(bytes, count: n)
  else { return false }
  var i: UInt64 = 36
  while i < n {
    guard little(bytes, at: i, bytes: 8) != 0 else { return false }
    i += 8
  }
  return true
}

// Only firmware data in a single validated, identity-mapped descriptor is
// readable, never an address from the ESP. Call before reclaiming any pages.
private func view(_ address: UInt64, acpi: Bool, in map: UnsafeBufferPointer<FirmwareRegion>)
  -> TableBytes?
{
  guard address != 0, let p = UnsafeRawPointer(bitPattern: UInt(address)) else { return nil }
  for r in map where address >= r.base && address - r.base < r.length {
    guard r.attributes & 0x2000 == 0 else { return nil }
    // ACPI objects may not live in reclaimable boot-services storage: child
    // table lifetimes extend beyond the handoff. The FDT is self-contained.
    guard
      r.type == 9 || r.type == 10 || r.type == 6
        || (!acpi && (r.type == 2 || r.type == 4))
    else { return nil }
    return TableBytes(data: p, length: min(32 << 20, r.length - (address - r.base)))
  }
  return nil
}

private func rootDirectory(_ rsdp: UInt64, in map: UnsafeBufferPointer<FirmwareRegion>)
  -> TableBytes?
{
  guard let root = view(rsdp, acpi: true, in: map), let addr = xsdtAddress(root),
    let xsdt = view(addr, acpi: true, in: map), validXSDT(xsdt)
  else { return nil }
  return xsdt
}

/// Return the enabled physical IDs in private scratch only after a complete
/// walk. Never try the DT as a fallback for a corrupt supplied ACPI directory.
/// Firmware IDs alone authorize neither CPU startup nor interrupt routing.
@unsafe public func firmwareProcessors(
  _ locations: FirmwareTableLocations, family: ProcessorFamily,
  in map: UnsafeBufferPointer<FirmwareRegion>,
  into scratch: UnsafeMutableBufferPointer<FirmwareProcessor>
) -> Int? {
  if locations.rsdp == 0 {
    guard let tree = view(locations.deviceTree, acpi: false, in: map) else { return nil }
    return treeProcessors(tree, family: family, into: scratch)
  }
  guard let root = rootDirectory(locations.rsdp, in: map) else { return nil }
  let n = little(root, at: 4, bytes: 4)
  guard (n - 36) / 8 <= 4096 else { return nil }
  var madt: TableBytes?
  var p: UInt64 = 36
  while p < n {
    guard let child = view(little(root, at: p, bytes: 8), acpi: true, in: map),
      child.length >= 36
    else { return nil }
    if little(child, at: 0, bytes: 4) == 0x4349_5041 {
      guard madt == nil else { return nil }
      madt = child
    }
    p += 8
  }
  guard let madt else { return nil }
  return madtProcessors(madt, family: family, into: scratch)
}

/// Call before reclaiming any pages. Only firmware data in a single validated,
/// identity-mapped descriptor is readable, never an address from the ESP.
@unsafe public func inspectFirmwareTables(
  _ locations: FirmwareTableLocations,
  in map: UnsafeBufferPointer<FirmwareRegion>
) -> InspectedFirmwareTables? {
  guard locations.rsdp != 0 || locations.deviceTree != 0 else { return nil }
  if locations.rsdp != 0 {
    guard rootDirectory(locations.rsdp, in: map) != nil else { return nil }
  }
  var size: UInt64 = 0
  if locations.deviceTree != 0 {
    guard let blob = view(locations.deviceTree, acpi: false, in: map) else { return nil }
    var cursor = openTree(blob)
    while !cursor.failed && !cursor.ended { _ = nextItem(blob, c: &cursor) }
    guard cursor.ended && !cursor.failed else { return nil }
    for i in 4..<8 { size = (size << 8) | UInt64(blob.byteAt(UInt64(i))) }
  }
  return InspectedFirmwareTables(
    rsdp: locations.rsdp, deviceTree: locations.deviceTree, treeBytes: size)
}

#if arch(arm64) || arch(riscv64) || (arch(x86_64) && (os(Windows) || TARBOOT_EFI_PE_COFF))
  // Only for the EFI entry system table after its full header was validated.
  func tableLocations(_ system: UnsafeRawPointer) -> FirmwareTableLocations? {
    let count = system.load(fromByteOffset: 104, as: UInt.self)
    guard count > 0, count <= 4096,
      let tables = system.load(fromByteOffset: 112, as: UnsafeRawPointer?.self),
      UInt(bitPattern: tables) & 7 == 0,
      validExtent(UInt64(UInt(bitPattern: tables)), length: UInt64(count) * 24)
    else { return nil }
    var acpi: UInt64 = 0
    var fdt: UInt64 = 0
    var finalEvents: UInt64 = 0
    for i in 0..<Int(count) {
      let entry = tables.advanced(by: i * 24)
      let head = entry.load(as: UInt64.self)
      let tail = entry.load(fromByteOffset: 8, as: UInt64.self)
      let addr = entry.load(fromByteOffset: 16, as: UInt64.self)
      if head == 0x11d3_e4f1_8868_e871 && tail == 0x8188_3cc7_8000_22bc {
        guard acpi == 0, addr != 0 else { return nil }
        acpi = addr
      }
      if head == 0x41a5_f19c_b1b6_21d5 && tail == 0xe0aa_692c_15d9_0b83 {
        guard fdt == 0, addr != 0 else { return nil }
        fdt = addr
      }
      if head == 0x4254_30e2_1e2e_d096 && tail == 0x2523_f8be_3b86_89bd {
        guard finalEvents == 0, addr != 0 else { return nil }
        finalEvents = addr
      }
    }
    return acpi == 0 && fdt == 0
      ? nil : FirmwareTableLocations(rsdp: acpi, deviceTree: fdt, finalEvents: finalEvents)
  }
#endif
