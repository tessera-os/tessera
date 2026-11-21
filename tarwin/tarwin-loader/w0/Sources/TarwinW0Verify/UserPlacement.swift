import TarwinLoader

/// Addresses only. A plan is not proof of PTEs, ASLR quality, private
/// memory, process-key installation, import signing, or RELRO sealing.
public struct W1AddressPlan {
  public let processReservation, libraryReservation: Range<UInt64>
  public let processEntry: UInt64
  /// The exact file-backed executable bytes, never a page-rounded range.
  public let libraryCode: Range<UInt64>
  public let slotAddress, targetAddress, storageModifier: UInt64
  /// All pages of init's writable load must be sealed before entry.
  public let sealReadOnly: Range<UInt64>
}

extension W1BootSet {
  /// Under exclusive map ownership, select both reservations from the same
  /// complete image map. Commit both or neither before releasing the lock.
  /// nextRandom must supply independent kernel CSPRNG draws or return nil.
  public func addressPlan(occupied: UnsafeBufferPointer<Range<UInt64>>, nextRandom: () -> UInt64?)
    -> W1AddressPlan?
  {
    let page: UInt64 = 16384
    func space(_ m: W1UserMember, _ extra: Range<UInt64>?) -> ImagePlacementSpace? {
      ImagePlacementSpace(
        machine: ElfMachine.aarch64, span: m.layout.reservationBytes,
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
    let end = ro.upperBound + ((page - ro.upperBound % page) % page)
    return W1AddressPlan(
      processReservation: p, libraryReservation: l,
      processEntry: p.lowerBound + process.layout.image.entry,
      libraryCode: (l.lowerBound + library.layout.code.lowerBound)..<(l.lowerBound
        + library.layout.code.upperBound),
      slotAddress: slot, targetAddress: l.lowerBound + binding.entryRVA,
      storageModifier: (slot & 0x0000_ffff_ffff_ffff) | (UInt64(binding.typeTag & 0xffff) << 48),
      sealReadOnly: (p.lowerBound + ro.lowerBound)..<(p.lowerBound + end))
  }
}
