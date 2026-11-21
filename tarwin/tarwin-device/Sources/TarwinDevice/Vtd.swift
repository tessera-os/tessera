/// Kernel-private VT-d table memory. All table pages are pinned, exclusively
/// owned and zero-filled before allocation returns. publish stores one
/// aligned little-endian word atomically and makes it visible to the walker
/// (including cache maintenance on noncoherent machines) before return.
public protocol VtdTableMemory: ~Copyable {
  mutating func allocateTable() -> UInt64?
  mutating func word(_ physical: UInt64) -> UInt64?
  mutating func publish(_ physical: UInt64, _ value: UInt64) -> Bool
}
/// Legacy second-level translation, 39-bit IOVA, 4 KiB pages. No scalable,
/// pass-through, large-page, ATS, PRI, PASID or peer assignment support.
public struct VtdDomain: ~Copyable {
  public let root: UInt64, id: UInt16
  private let maximum: UInt64
  public init?<M: VtdTableMemory & ~Copyable>(id: UInt16, physicalBits: UInt8, memory: inout M) {
    guard id != 0, (32...52).contains(physicalBits) else { return nil }
    let maximum = (UInt64(1) << physicalBits) - 1
    guard let root = memory.allocateTable(), Self.page(root, maximum) else { return nil }
    self.root = root
    self.id = id
    self.maximum = maximum
  }
  private static func page(_ p: UInt64, _ maximum: UInt64) -> Bool {
    p != 0 && (p & 4095) == 0 && p <= maximum - 4095
  }
  private func leaf<M: VtdTableMemory & ~Copyable>(_ iova: UInt64, create: Bool, memory: inout M)
    -> UInt64?
  {
    guard iova != 0, iova & 4095 == 0, iova < (1 << 39) else { return nil }
    var level = root
    var shift = 30
    while shift > 12 {
      let slot = level + ((iova >> shift) & 511) * 8
      guard let entry = memory.word(slot) else { return nil }
      if entry == 0 {
        guard create, let page = memory.allocateTable(), Self.page(page, maximum),
          memory.publish(slot, page | 3)
        else { return nil }
        level = page
      } else {
        let next = entry & ~UInt64(4095)
        guard entry & 4095 == 3, Self.page(next, maximum) else { return nil }
        level = next
      }
      shift -= 9
    }
    return level + ((iova >> 12) & 511) * 8
  }
  /// The slot/domain owner supplies only a currently pinned, authorized frame.
  /// An existing entry cannot be widened or overwritten. Do not reuse a
  /// detached IOVA until the unit acknowledges invalidation and drain.
  public func mapPage<M: VtdTableMemory & ~Copyable>(
    iova: UInt64, frame: UInt64, access: DmaAccess, memory: inout M
  ) -> Bool {
    guard Self.page(frame, maximum), let entry = leaf(iova, create: true, memory: &memory),
      memory.word(entry) == 0
    else { return false }
    let bits: UInt64 =
      switch access {
      case .deviceRead: 1
      case .deviceWrite: 2
      case .both: 3
      }
    return memory.publish(entry, frame | bits)
  }
  public func detach<M: VtdTableMemory & ~Copyable>(iova: UInt64, frame: UInt64, memory: inout M)
    -> Bool
  {
    guard Self.page(frame, maximum), let e = leaf(iova, create: false, memory: &memory),
      let old = memory.word(e),
      old & 3 != 0, old & ~UInt64(3) == frame
    else { return false }
    return memory.publish(e, frame)
  }
  /// Non-present, nonzero leaves quarantine the IOVA across failed drains;
  /// the ordinary mapping path requires a zero slot. No ATS is enabled.
  public func drainDetached<M: VtdTableMemory & ~Copyable, R: VtdRegisters & ~Copyable>(
    iova: UInt64, frame: UInt64, unit: VtdLegacyUnit, memory: inout M, registers: inout R
  ) -> Bool {
    guard Self.page(frame, maximum), let e = leaf(iova, create: false, memory: &memory),
      memory.word(e) == frame, unit.flushTranslations(registers: &registers)
    else { return false }
    return memory.publish(e, 0)
  }
  /// Install only on an isolated requester/group with bus mastering and ATS
  /// blocked. The platform includes aliases, enforces unique domain IDs,
  /// and drains the context cache before enabling any requester.
  public func bind<M: VtdTableMemory & ~Copyable>(
    rootTable: UInt64, requester: UInt16, unit: VtdLegacyUnit, memory: inout M
  ) -> VtdBinding? {
    guard id <= unit.maxDomain, Self.page(rootTable, maximum), rootTable != root else { return nil }
    let re = rootTable + UInt64(requester >> 8) * 16
    guard let old = memory.word(re), memory.word(re + 8) == 0 else { return nil }
    let ct: UInt64
    if old == 0 {
      guard let page = memory.allocateTable(), Self.page(page, maximum),
        memory.publish(re, page | 1)
      else { return nil }
      ct = page
    } else {
      ct = old & ~UInt64(4095)
      guard old & 4095 == 1, Self.page(ct, maximum) else { return nil }
    }
    let ce = ct + UInt64(requester & 255) * 16
    guard memory.word(ce) == 0, memory.word(ce + 8) == 0 else { return nil }
    let high = UInt64(id) << 8 | 1
    guard memory.publish(ce + 8, high), memory.publish(ce, root | 1) else { return nil }
    return VtdBinding(entry: ce, low: root | 1, high: high)
  }
}

/// Keep the requester and its domain ID quarantined on failure; retry
/// under the same unit lock. Do not assign the requester or free the
/// tables until every alias binding has completed teardown.
public struct VtdBinding: ~Copyable {
  private let entry: UInt64, low: UInt64, high: UInt64
  private enum Phase { case bound, context, iotlb, release, retired }
  private var phase: Phase = .bound
  fileprivate init(entry: UInt64, low: UInt64, high: UInt64) {
    self.entry = entry
    self.low = low
    self.high = high
  }
  public mutating func retire<M: VtdTableMemory & ~Copyable, R: VtdRegisters & ~Copyable>(
    requesterStoppedAndDrained: Bool, unit: VtdLegacyUnit, memory: inout M, registers: inout R
  ) -> Bool {
    guard requesterStoppedAndDrained else { return false }
    if phase == .bound {
      guard memory.word(entry) == low, memory.word(entry + 8) == high, memory.publish(entry, 0)
      else { return false }
      phase = .context
    }
    if phase == .context {
      guard unit.flushContexts(registers: &registers) else { return false }
      phase = .iotlb
    }
    if phase == .iotlb {
      guard unit.flushTranslations(registers: &registers) else { return false }
      phase = .release
    }
    if phase == .release {
      guard memory.word(entry) == 0, memory.word(entry + 8) == high, memory.publish(entry + 8, 0)
      else { return false }
      phase = .retired
    }
    return true
  }
}

/// Ordered uncached remapping-unit register access. expired is relative to
/// a platform monotonic deadline, not the number of poll iterations.
public protocol VtdRegisters: ~Copyable {
  mutating func read32(_ offset: UInt32) -> UInt32
  mutating func read64(_ offset: UInt32) -> UInt64
  mutating func write32(_ offset: UInt32, _ value: UInt32)
  mutating func write64(_ offset: UInt32, _ value: UInt64)
  mutating func expired() -> Bool
}
public struct VtdLegacyUnit {
  private let iotlb: UInt32
  public let maxDomain: UInt16
  public init?<R: VtdRegisters & ~Copyable>(registerBytes: UInt32, registers r: inout R) {
    guard registerBytes >= 0x38 else { return nil }
    let cap = r.read64(8)
    let ecap = r.read64(16)
    let offset = UInt32((ecap >> 8) & 1023) * 16 + 8
    // Require three-level walks, read/write draining and no write-buffer flush requirement.
    guard cap != .max, ecap != .max, cap & (1 << 9) != 0, cap & (3 << 54) == (3 << 54),
      (cap >> 16) & 63 >= 38, cap & 16 == 0, (cap & 7) <= 6, offset >= 0x38,
      offset <= registerBytes - 8
    else { return nil }
    iotlb = offset
    maxDomain = UInt16(truncatingIfNeeded: (UInt64(1) << min(16, 4 + 2 * Int(cap & 7))) - 1)
  }
  private func status<R: VtdRegisters & ~Copyable>(_ bit: UInt32, _ r: inout R) -> Bool {
    while true {
      let value = r.read32(0x1c)
      if value == .max { return false }
      if value & bit != 0 { return true }
      if r.expired() { return false }
    }
  }
  /// No takeover of active translation, queued invalidation, interrupt
  /// remapping or firmware-owned roots. On timeout keep bus mastering blocked.
  public func start<R: VtdRegisters & ~Copyable>(
    root: UInt64, allRequestersBlocked: Bool, atsDisabled: Bool, registers r: inout R
  ) -> Bool {
    guard allRequestersBlocked, atsDisabled, root != 0, root >> 52 == 0, root & 4095 == 0,
      r.read32(0x1c) == 0
    else {
      return false
    }
    r.write64(0x20, root)
    guard r.read64(0x20) == root else { return false }
    r.write32(0x18, 1 << 30)
    guard status(1 << 30, &r) else { return false }
    guard flushContexts(registers: &r), flushTranslations(registers: &r) else { return false }
    r.write32(0x18, 1 << 31)
    return status(1 << 31, &r)
  }
  public func flushContexts<R: VtdRegisters & ~Copyable>(registers r: inout R) -> Bool {
    let busy: UInt64 = 1 << 63
    guard r.read32(0x1c) & (1 << 26) == 0, r.read64(0x28) & busy == 0 else { return false }
    r.write64(0x28, busy | (1 << 61))
    while true {
      let value = r.read64(0x28)
      if value & busy == 0 { return (value >> 59) & 3 == 1 }
      if r.expired() { return false }
    }
  }
  public func flushTranslations<R: VtdRegisters & ~Copyable>(registers r: inout R) -> Bool {
    let busy: UInt64 = 1 << 63
    guard r.read32(0x1c) & (1 << 26) == 0, r.read64(iotlb) & busy == 0 else { return false }
    r.write64(iotlb, busy | (1 << 60) | (3 << 48))
    while true {
      let value = r.read64(iotlb)
      if value & busy == 0 { return (value >> 57) & 3 == 1 }
      if r.expired() { return false }
    }
  }
}
