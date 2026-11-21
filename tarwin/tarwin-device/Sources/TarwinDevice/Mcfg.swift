import KCore

/// The physical window starts at firstBus, whereas the MCFG allocation's
/// base address corresponds to bus zero. Neither grants a device or a BAR.
public struct FirmwareEcam: Equatable {
  public let segment: UInt16, firstBus: UInt8, lastBus: UInt8, registers: DeviceRange
  public func address(
    bus: UInt32, device: UInt32, function: UInt32, register: UInt32,
    width: UInt32
  ) -> UInt64? {
    guard bus >= firstBus, bus <= lastBus, device < 32, function < 8,
      width == 1 || width == 2 || width == 4, register < 4096, register % width == 0
    else { return nil }
    let offset = (bus - UInt32(firstBus)) << 20 | device << 15 | function << 12 | register
    return registers.base + UInt64(offset)
  }
}

private func mcfgWindow<S: ByteSource>(_ s: S, _ p: UInt64) -> FirmwareEcam? {
  let base = little(s, at: p, bytes: 8)
  let segment = UInt16(little(s, at: p + 8, bytes: 2))
  let first = s.byteAt(p + 10)
  let last = s.byteAt(p + 11)
  let skip = UInt64(first) << 20
  guard base != 0, deviceAligned(base, 1 << 20), base <= UInt64.max - skip,
    first <= last, little(s, at: p + 12, bytes: 4) == 0
  else { return nil }
  let r = DeviceRange(base: base + skip, length: (UInt64(last - first) + 1) << 20)
  guard r.valid() else { return nil }
  return FirmwareEcam(segment: segment, firstBus: first, lastBus: last, registers: r)
}

/// Supply the entire immutable MCFG selected by the validated ACPI root.
/// Keep the resulting mapping device/uncached; authorize its whole extent
/// against the platform's reserved MMIO map, independent of this table.
public func firmwareEcam<S: ByteSource>(
  _ table: S, segment: UInt16, bus: UInt8,
  reservedRegisters: (DeviceRange) -> Bool
) -> FirmwareEcam? {
  let n = table.byteCount()
  guard n >= 60, n <= 44 + 256 * 16, (n - 44) % 16 == 0,
    little(table, at: 0, bytes: 4) == 0x4746_434d, little(table, at: 4, bytes: 4) == n,
    table.byteAt(8) == 1, little(table, at: 36, bytes: 8) == 0
  else { return nil }
  var sum: UInt8 = 0
  for i in 0..<n { sum &+= table.byteAt(i) }
  guard sum == 0 else { return nil }
  var selected: FirmwareEcam?
  var p: UInt64 = 44
  while p < n {
    guard let w = mcfgWindow(table, p) else { return nil }
    var q: UInt64 = 44
    while q < p {
      guard let prior = mcfgWindow(table, q), !w.registers.overlaps(prior.registers),
        prior.segment != w.segment || prior.lastBus < w.firstBus || w.lastBus < prior.firstBus
      else { return nil }
      q += 16
    }
    if w.segment == segment && w.firstBus <= bus && bus <= w.lastBus { selected = w }
    p += 16
  }
  guard let selected, reservedRegisters(selected.registers) else { return nil }
  return selected
}
