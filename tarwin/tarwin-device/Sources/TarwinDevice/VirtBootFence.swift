/// Called by the exclusive boot CPU after firmware and all other submitters
/// have stopped. The accessors are ordered, exact-width accesses, not probes
/// into arbitrary physical memory. The two work pages are private, coherent,
/// normal RAM owned by the kernel. Keep both pinned even on partial failure.
public protocol VirtBootFenceReadBus: ColdVirtReadRegisters, ~Copyable {
  mutating func read8(_ physical: UInt64) -> UInt8?
  mutating func read64(_ physical: UInt64) -> UInt64?
}

public protocol VirtBootFenceBus: VirtBootFenceReadBus, ColdVirtRegisters, ~Copyable {
  mutating func write8(_ physical: UInt64, _ value: UInt8) -> Bool
  mutating func write16(_ physical: UInt64, _ value: UInt16) -> Bool
  mutating func write64(_ physical: UInt64, _ value: UInt64) -> Bool
  /// Order prior RAM stores before publishing the stream table and command producer.
  mutating func publishStores()
}

public enum VirtBootFenceResult: Equatable {
  case badMemory, unsupported, drainFailed, abortFailed, tableFailed, syncFailed, streamsDenied
}

/// Selected by the trusted machine launcher, never inferred from the BAR.
/// The optional virt-11.1 high aperture is identity mapped, 512 GiB at 512 GiB.
public enum VirtBootPCILayout { case lowOnly, virt11High512GiB }

// Validate all decoders before attempting either MMIO reset.
private struct ResetWindow {
  let function: UInt64, common: DeviceRange, msix: DeviceRange
  init?<B: VirtBootFenceReadBus & ~Copyable>(
    _ function: UInt64, _ layout: VirtBootPCILayout, _ b: inout B
  ) {
    guard let command = b.read32(function + 4), command & 0x10_0002 == 0x10_0002,
      let first = b.read8(function + 0x34)
    else { return nil }
    var at = UInt64(first)
    var visited: UInt64 = 0
    var found = false
    while at != 0 {
      guard at >= 64, at <= 252, at % 4 == 0 else { return nil }
      let bit = UInt64(1) << (at / 4)
      guard visited & bit == 0, let cap = b.read32(function + at) else { return nil }
      visited |= bit
      let p = function + at
      if cap & 255 == 9 {
        let length = UInt64(cap >> 16 & 255)
        guard length >= 4, at + length <= 256 else { return nil }
        switch cap >> 24 {
        case 1:
          guard !found, length >= 16, b.read8(p + 4) == 4, b.read32(p + 8) == 0,
            let bytes = b.read32(p + 12), (56...4096).contains(bytes)
          else { return nil }
          found = true
        default: break
        }
      }
      at = UInt64(cap >> 8 & 255)
    }
    guard found, b.read32(function + 0x10) == 0, let m = b.read32(function + 0x14),
      m & 0xfff == 0, b.read32(function + 0x18) == 0, b.read32(function + 0x1c) == 0,
      let low = b.read32(function + 0x20), low & 0x3fff == 12, let high = b.read32(function + 0x24)
    else { return nil }
    let lowHole = DeviceRange(base: 0x1000_0000, length: 0x2eff_0000)
    let highHole = DeviceRange(base: 0x80_0000_0000, length: 0x80_0000_0000)
    common = DeviceRange(base: UInt64(high) << 32 | UInt64(low & ~15), length: 16384)
    msix = DeviceRange(base: UInt64(m), length: 4096)
    guard lowHole.contains(common) || (layout == .virt11High512GiB && highHole.contains(common)),
      lowHole.contains(msix), !msix.overlaps(common)
    else { return nil }
    self.function = function
  }

  func drain<B: VirtBootFenceBus & ~Copyable>(_ b: inout B) -> Bool {
    // VERSION_1 and ACCESS_PLATFORM are advertised by both fixed endpoints;
    // absent decode must not look like a successful zero status.
    guard b.write32(common.base, 1), let features = b.read32(common.base + 4), features & 3 == 3,
      b.write8(common.base + 20, 0)
    else { return false }
    for _ in 0..<256 {
      guard let status = b.read8(common.base + 20) else { return false }
      if status == 0 {
        guard let command = b.read32(function + 4),
          b.write16(function + 4, UInt16(truncatingIfNeeded: command) & ~4),
          let parked = b.read32(function + 4), parked & 4 == 0
        else { return false }
        return true
      }
    }
    return false
  }
}

private func validFencePages(
  _ table: UInt64, _ commands: UInt64, _ protected: UnsafeBufferPointer<DeviceRange>
) -> Bool {
  let ram = DeviceRange(base: 0x4000_0000, length: 512 << 20)
  let t = DeviceRange(base: table, length: 4096)
  let q = DeviceRange(base: commands, length: 4096)
  guard ram.contains(t), ram.contains(q), table != commands, (table | commands) & 4095 == 0,
    protected.count > 0, protected.count <= 4096
  else { return false }
  for extent in protected {
    guard ram.contains(extent), !t.overlaps(extent), !q.overlaps(extent) else { return false }
  }
  return true
}
private func commandWord(_ i: Int) -> UInt64 {
  switch i {
  case 0: 4
  case 1: 31
  case 2: 0x30
  case 4: 0x46
  default: 0
  }
}
private func supportedFenceSmmu<B: VirtBootFenceReadBus & ~Copyable>(_ b: inout B) -> Bool {
  let s: UInt64 = 0x0905_0000
  guard let id0 = b.read32(s), id0 & 0x10 != 0, id0 & (1 << 10) == 0,
    let id1 = b.read32(s + 4), id1 & 63 >= 6, (id1 >> 21) & 31 >= 3,
    id1 & 0xe000_0000 == 0
  else { return false }
  return true
}

/// Fixed cold virt-11.1 profile only (same external launch restrictions as
/// requestColdVirtPCIAbort). Denies *all* PCI DMA; there is no allowed range
/// to subtract the archive from. Protected extents keep work pages from
/// overwriting the caller's archive, verification scratch or staged images.
/// This is not a VM generation check, a snapshot restore gate or an EL0 permit.
public func denyVirtBootDMA<B: VirtBootFenceBus & ~Copyable>(
  table: UInt64, commands: UInt64, protected: UnsafeBufferPointer<DeviceRange>,
  layout: VirtBootPCILayout = .lowOnly, bus b: inout B
) -> VirtBootFenceResult {
  guard validFencePages(table, commands, protected) else { return .badMemory }
  let s: UInt64 = 0x0905_0000
  guard coldVirtInventory(&b, firmwareEndpoints: true) == nil, coldVirtSmmuCheck(&b) == nil,
    supportedFenceSmmu(&b), b.read32(s + 0x98) == 0, b.read32(s + 0x9c) == 0,
    let disk = ResetWindow(0x40_1000_8000, layout, &b),
    let rng = ResetWindow(0x40_1001_0000, layout, &b),
    !disk.common.overlaps(rng.common), !disk.msix.overlaps(rng.common),
    !rng.msix.overlaps(disk.common), !disk.msix.overlaps(rng.msix)
  else { return .unsupported }
  guard disk.drain(&b), rng.drain(&b) else { return .drainFailed }
  guard requestColdVirtPCIAbort(registers: &b) == .pciAbortAcknowledged else { return .abortFailed }

  // Linear table: 64 valid, abort-only STEs. Larger stream IDs fault.
  for i in 0..<512 {
    guard b.write64(table + UInt64(8 * i), i % 8 == 0 ? 1 : 0) else { return .tableFailed }
  }
  // Eight 128-bit commands fit the ring. Publish three: CFGI_ALL (range=31),
  // TLBI_NSNH_ALL and CMD_SYNC without an MSI or completion-memory write.
  for i in 0..<16 {
    guard b.write64(commands + UInt64(8 * i), commandWord(i)) else { return .tableFailed }
  }
  b.publishStores()
  guard b.write32(s + 0x28, 0xd75), b.read32(s + 0x28) == 0xd75,
    b.write64(s + 0x80, table), b.read64(s + 0x80) == table,
    b.write32(s + 0x88, 6), b.read32(s + 0x88) == 6,
    b.write64(s + 0x90, commands | 3), b.read64(s + 0x90) == commands | 3
  else { return .tableFailed }
  func wait(_ p: UInt64, _ value: UInt32, _ b: inout B) -> Bool {
    for _ in 0..<256 {
      guard b.read32(s + 0x60) == 0, b.read32(s + 0x64) == 0,
        let actual = b.read32(p)
      else { return false }
      if actual == value { return true }
    }
    return false
  }
  guard b.write32(s + 0x20, 8), wait(s + 0x24, 8, &b), b.write32(s + 0x98, 3),
    wait(s + 0x9c, 3, &b), b.write32(s + 0x20, 9), wait(s + 0x24, 9, &b),
    b.read32(s + 0x44) == 0x10_1000
  else { return .syncFailed }
  return .streamsDenied
}

public enum VirtBootContinuityResult: Equatable {
  case badMemory, wrongPlatform, endpointChanged, controllerChanged, tableChanged, commandsChanged
  case matchesColdFence
}

/// Companion check, not fence installation or an entry permit. The original
/// deny must have succeeded *before* verified image installation. Trusted
/// launch excludes restore, hotplug and other writers from then through this
/// call. The handoff pins both pages and authenticates their addresses; never
/// use a live STRTAB_BASE or CMDQ_BASE as a pointer to walk memory.
public func checkVirtBootDMAContinuity<B: VirtBootFenceReadBus & ~Copyable>(
  table: UInt64, commands: UInt64, protected: UnsafeBufferPointer<DeviceRange>, bus b: inout B
) -> VirtBootContinuityResult {
  guard validFencePages(table, commands, protected) else { return .badMemory }
  guard coldVirtInventory(&b, firmwareEndpoints: false) == nil,
    coldVirtSmmuIdentity(&b), supportedFenceSmmu(&b)
  else { return .wrongPlatform }
  guard let disk = ResetWindow(0x40_1000_8000, .lowOnly, &b),
    let rng = ResetWindow(0x40_1001_0000, .lowOnly, &b),
    !disk.common.overlaps(rng.common), !disk.msix.overlaps(rng.common),
    !rng.msix.overlaps(disk.common), !disk.msix.overlaps(rng.msix),
    b.read8(disk.common.base + 20) == 0, b.read8(rng.common.base + 20) == 0
  else { return .endpointChanged }
  let s: UInt64 = 0x0905_0000
  func active(_ b: inout B) -> Bool {
    b.read32(s + 0x20) == 9 && b.read32(s + 0x24) == 9 && b.read32(s + 0x28) == 0xd75
      && b.read32(s + 0x44) == 0x10_1000 && b.read32(s + 0x50) == 0 && b.read32(s + 0x54) == 0
      && b.read32(s + 0x60) == 0 && b.read32(s + 0x64) == 0
      && b.read64(s + 0x80) == table && b.read32(s + 0x88) == 6
      && b.read64(s + 0x90) == commands | 3 && b.read32(s + 0x98) == 3 && b.read32(s + 0x9c) == 3
  }
  guard active(&b) else { return .controllerChanged }
  for i in 0..<512 {
    guard b.read64(table + UInt64(i * 8)) == (i % 8 == 0 ? 1 : 0) else { return .tableChanged }
  }
  for i in 0..<16 {
    guard b.read64(commands + UInt64(i * 8)) == commandWord(i) else { return .commandsChanged }
  }
  return active(&b) ? .matchesColdFence : .controllerChanged
}
