/// CPU-side accounting for a bounded, read-only storage request. These are
/// page uses, not device permissions or a grant to enable a queue.
public enum ReadQueuePageUse { case submission, completion, destination }

/// Kernel-only. Dropping a live pin leaks its charge rather than making the
/// frames reusable. Keep it in the domain backend's private retirement record.
public struct ReadQueuePin: ~Copyable {
  public let group, epoch, physical, bytes: UInt64
  public let use: ReadQueuePageUse
  fileprivate let pool: UnsafeMutableRawPointer
  fileprivate let order: UInt8
  public fileprivate(set) var held = true
}

/// One kernel-owned allocator leaf dedicated to one slot generation. Serialize
/// this pool with that slot. It neither installs nor attests IOMMU mappings.
public struct ReadQueuePinPool: ~Copyable {
  private enum Phase { case issuing, draining, failed }
  private var phase = Phase.issuing
  private var pages: MonitoredPageArena
  private let ram: UnsafeMutableRawBufferPointer
  public let group, epoch: UInt64
  public let limitPages: Int
  public private(set) var chargedPages = 0

  /// Supply the exclusive kernel mapping of exactly this leaf. Keep it and
  /// its allocator metadata pinned, disjoint and unreachable by unrelated
  /// CPUs/devices. Never reconstruct the allocator while any pin is outstanding.
  @unsafe public init?(pages: consuming MonitoredPageArena, mapped: UnsafeMutableRawBufferPointer,
    group: UInt64, epoch: UInt64, limitPages: Int) {
    guard epoch != 0, (1...64).contains(limitPages), pages.base != 0, !pages.hasAllocations,
      let p = mapped.baseAddress,
      UInt(bitPattern: p) & UInt(pages.pageSize - 1) == 0,
      mapped.count == Int(pages.pageSize) * 64, pages.hasSeparateCounters(from: mapped) else { return nil }
    self.pages = consume pages
    self.ram = mapped
    self.group = group
    self.epoch = epoch
    self.limitPages = limitPages
  }

  public mutating func take(order: UInt8, use: ReadQueuePageUse) -> ReadQueuePin? {
    guard phase == .issuing, order <= 6 else { return nil }
    let count = 1 << Int(order)
    guard count <= limitPages - chargedPages else { return nil }
    let block = pages.take(order: order)
    guard block.ok else { return nil }
    let bytes = count * Int(pages.pageSize)
    let offset = Int(block.address - pages.base)
    ram[offset..<offset + bytes].initializeMemory(as: UInt8.self, repeating: 0)
    chargedPages += count
    return ReadQueuePin(group: group, epoch: epoch, physical: block.address,
      bytes: UInt64(bytes), use: use, pool: ram.baseAddress!, order: order)
  }

  /// Call only for a never-mapped pin or from the trusted retirement callback
  /// after acknowledged detach, invalidation, device-cache and write drain.
  /// Indeterminate completion must leave the pin and its charge intact.
  @unsafe public mutating func releaseRetired(_ pin: inout ReadQueuePin) -> Bool {
    guard phase != .failed, pin.held, pin.group == group, pin.epoch == epoch, pin.pool == ram.baseAddress,
      pin.physical >= pages.base, pin.physical - pages.base < UInt64(ram.count),
      pin.bytes <= UInt64(ram.count) - (pin.physical - pages.base),
      pages.give(address: pin.physical, order: pin.order) else { return false }
    let offset = Int(pin.physical - pages.base)
    ram[offset..<offset + Int(pin.bytes)].initializeMemory(as: UInt8.self, repeating: 0)
    chargedPages -= 1 << Int(pin.order)
    pin.held = false
    return true
  }

  public mutating func corrected(at physical: UInt64) -> PageErrorAction {
    pages.corrected(at: physical)
  }

  /// Stop issuing pins for this epoch. Existing pins remain charged.
  public mutating func beginRetirement() {
    if phase == .issuing { phase = .draining }
  }

  /// On failure the reservation stays unavailable, never reconstructed from
  /// its address. Retire every pin before attempting this final hand-back.
  public consuming func reclaim() -> MonitoredPageArena? {
    guard phase == .draining, chargedPages == 0 else { return nil }
    return consume pages
  }

  public mutating func uncorrectable(at physical: UInt64) -> PageErrorAction {
    let action = pages.uncorrectable(at: physical) { _ in .kernelOrUnknown }
    if action == .kernelPanic { phase = .failed }
    return action
  }
}
