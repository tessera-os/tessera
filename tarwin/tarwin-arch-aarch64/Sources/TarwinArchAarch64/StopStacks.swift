/// Two pinned kernel-only stack runs in one immutable direct-permission
/// TTBR1. The CPU owner reserves their guard pages and excludes aliases,
/// DMA and reuse until every pending handoff using this layout has drained.
public struct ArmStopStacks {
  public let root: UInt64
  public let outgoing, scheduler: Range<UInt64>

  public init?(
    tables: borrowing ArmKernelTranslation, outgoingVA: UInt64, outgoingPA: UInt64,
    schedulerVA: UInt64, schedulerPA: UInt64
  ) {
    let page: UInt64 = 16384
    func stack(_ va: UInt64, _ pa: UInt64) -> Range<UInt64>? {
      guard va >= 0xffff_8000_0000_0000 + page, va <= .max - 2 * page,
        pa < 1 << 48, tables.isGuard(va - page),
        tables.mapsPrivateDataPage(va, physical: pa),
        tables.mapsPrivateDataPage(va + page, physical: pa + page)
      else { return nil }
      return va..<va + 2 * page
    }
    guard let a = stack(outgoingVA, outgoingPA), let b = stack(schedulerVA, schedulerPA),
      !a.overlaps(b),
      !(outgoingPA..<outgoingPA + 2 * page).overlaps(schedulerPA..<schedulerPA + 2 * page)
    else { return nil }
    root = tables.physicalRoot
    outgoing = a
    scheduler = b
  }

  public func destination(frame: UInt64, hostRoot: UInt64) -> UInt64? {
    guard hostRoot == root, frame & 15 == 0, outgoing.contains(frame),
      outgoing.upperBound - frame >= UInt64(ArmTrapLayout.size)
    else { return nil }
    return scheduler.upperBound
  }
}
