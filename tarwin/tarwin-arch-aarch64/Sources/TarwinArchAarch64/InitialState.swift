enum ArmEntryPage { case guardPage, code, data }

/// First thread state only, never a frame for resuming a trapped thread.
/// FPCR=0 is round-to-nearest-even, no flush-to-zero, no exception traps.
@available(macOS 26, *)
public struct ArmInitialState {
  public private(set) var gpr = InlineArray<31, UInt64>(repeating: 0)
  public let vectorHalves = InlineArray<64, UInt64>(repeating: 0)
  public let fpcr: UInt64 = 0, fpsr: UInt64 = 0, spsr: UInt64 = 0
  public let elr: UInt64, sp: UInt64, tpidr: UInt64

  /// Supply the verified process entry/RX, the installed bootstrap channel
  /// name (not its address), initialized TCB and committed stack from the
  /// same process, under exclusive map ownership. This checks descriptors,
  /// not image signatures, handle rights, TCB contents, or PAC/GCS setup.
  public init?(tables: borrowing ArmUserTranslation, entry: UInt64, imageRX: Range<UInt64>,
    bootstrapChannel: UInt64, stack: Range<UInt64>, tcb: UInt64) {
    let page: UInt64 = 16384, guardBytes: UInt64 = 65536
    let ordinary: UInt64 = 1 << 43, limit: UInt64 = 1 << 46
    guard bootstrapChannel != 0, entry & 15 == 0, imageRX.lowerBound >= 1 << 32,
      imageRX.upperBound <= ordinary, imageRX.contains(entry), imageRX.upperBound - entry >= 4,
      entry - imageRX.lowerBound >= 4, tables.entryPage(entry - 4, is: .code),
      tables.entryPage(entry, is: .code),
      !stack.isEmpty, (stack.lowerBound | stack.upperBound) & (page - 1) == 0,
      stack.lowerBound >= ordinary + guardBytes, stack.upperBound < limit,
      tcb >= ordinary, tcb <= limit - 64, tcb & 63 == 0,
      tcb + 64 <= stack.lowerBound - guardBytes || tcb >= stack.upperBound,
      tables.entryPage(tcb, is: .data)
    else { return nil }
    var va = stack.lowerBound - guardBytes
    while va < stack.upperBound {
      guard tables.entryPage(va, is: va < stack.lowerBound ? .guardPage : .data)
      else { return nil }
      va += page
    }
    self.elr = entry
    self.sp = stack.upperBound
    self.tpidr = tcb
    self.gpr[0] = bootstrapChannel
  }
}
