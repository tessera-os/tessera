import TarwinLoader

public enum W1SlotFormat: Equatable {
  case armProcessIA(modifier: UInt64)
  case x64IBT(tag: UInt32)
  case rv64LPAD(tag: UInt32, label: UInt32)

  static func select(machine: UInt16, slot: UInt64, tag: UInt32) -> Self? {
    switch machine {
    case ElfMachine.aarch64: return .armProcessIA(modifier: W1AddressPlan.importModifier(slot: slot, tag: tag))
    case ElfMachine.x64: return .x64IBT(tag: tag)
    case ElfMachine.rv64: return .rv64LPAD(tag: tag, label: tag & 0xfffff)
    default: return nil
    }
  }
}

/// Addresses only. A plan is not proof of PTEs, ASLR quality, private
/// memory, process-key installation, import signing, or RELRO sealing.
public struct W1AddressPlan {
  public let machine: UInt16
  public let processReservation, libraryReservation: Range<UInt64>
  public let processEntry: UInt64
  /// The exact file-backed executable bytes, never a page-rounded range.
  public let libraryCode: Range<UInt64>
  public let slotAddress, targetAddress: UInt64
  public let slotFormat: W1SlotFormat
  /// Legacy Arm-only bootstrap API. There is no PAC modifier on x64 or RV64.
  public var storageModifier: UInt64 {
    guard case .armProcessIA(let modifier) = slotFormat else { return 0 }
    return modifier
  }
  /// All pages of init's writable load must be sealed before entry.
  public let sealReadOnly: Range<UInt64>

  static func importModifier(slot: UInt64, tag: UInt32) -> UInt64 {
    (slot & 0x0000_ffff_ffff_ffff) | (UInt64(tag & 0xffff) << 48)
  }
}

extension W1BootSet {
  /// Under exclusive map ownership, select both reservations from the same
  /// complete image map. Commit both or neither before releasing the lock.
  /// nextRandom must supply independent kernel CSPRNG draws or return nil.
  public func addressPlan(occupied: UnsafeBufferPointer<Range<UInt64>>, nextRandom: () -> UInt64?)
    -> W1AddressPlan?
  {
    // Legacy PAC bootstrap is AArch64-only.
    addressPlan(for: ElfMachine.aarch64, occupied: occupied, nextRandom: nextRandom)
  }

  public func addressPlan(for target: UInt16, occupied: UnsafeBufferPointer<Range<UInt64>>,
    nextRandom: () -> UInt64?) -> W1AddressPlan?
  {
    let page = imagePage(machine)
    guard machine == target, page != 0 else { return nil }
    func space(_ m: W1UserMember, _ extra: Range<UInt64>?) -> ImagePlacementSpace? {
      ImagePlacementSpace(
        machine: machine, span: m.layout.reservationBytes,
        alignment: m.layout.biasAlignment, occupied: occupied, excluding: extra)
    }
    func pick(_ s: ImagePlacementSpace) -> Range<UInt64>? {
      guard s.positions >= minimumImagePositions else { return nil }
      for _ in 0..<64 {
        guard let word = nextRandom() else { return nil }
        if let r = s.reservation(randomWord: word) { return r }
      }
      return nil
    }
    // If success depended on where init landed, repeating a failed pair
    // could bias init. Budget for the worst-case number of framework starts
    // one init reservation can exclude before drawing either bias.
    guard let ps = space(process, nil), ps.positions >= minimumImagePositions,
      let ls = space(library, nil), ls.positions >= minimumImagePositions
    else { return nil }
    let intersecting = process.layout.reservationBytes + library.layout.reservationBytes - 2 * page
    let worstLost = 1 + intersecting / library.layout.biasAlignment
    guard ls.positions >= minimumImagePositions + worstLost, let p = pick(ps),
      let remaining = space(library, p), let l = pick(remaining),
      process.layout.code.contains(process.layout.image.entry),
      library.layout.code.contains(binding.entryRVA),
      let ro = process.layout.relroBytes, ro.contains(binding.slotRVA),
      ro.upperBound - binding.slotRVA >= 8
    else { return nil }
    let slot = p.lowerBound + binding.slotRVA
    guard let format = W1SlotFormat.select(machine: machine, slot: slot, tag: binding.typeTag)
    else { return nil }
    let end = ro.upperBound + ((page - ro.upperBound % page) % page)
    return W1AddressPlan(
      machine: machine, processReservation: p, libraryReservation: l,
      processEntry: p.lowerBound + process.layout.image.entry,
      libraryCode: (l.lowerBound + library.layout.code.lowerBound)..<(l.lowerBound
        + library.layout.code.upperBound),
      slotAddress: slot, targetAddress: l.lowerBound + binding.entryRVA,
      slotFormat: format,
      sealReadOnly: (p.lowerBound + ro.lowerBound)..<(p.lowerBound + end))
  }
}
