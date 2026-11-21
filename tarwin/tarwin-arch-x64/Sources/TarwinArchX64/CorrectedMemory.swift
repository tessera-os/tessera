/// Intel architectural MCA memory-controller read/write errors only.
/// A nil result is unclassified evidence: preserve the bank and escalate,
/// never clear it or attribute it to a guessed frame. The board must have
/// established MCA support, the bank's ownership and its Intel format.
public func x64CorrectedMemoryPage(status: UInt64, address: UInt64, misc: UInt64,
  physicalBits: UInt8) -> UInt64? {
  // VAL, EN, MISCV, ADDRV. Reject overflow, UC, PCC, action-required,
  // model-specific bits and aggregated reports we cannot count exactly.
  let flags: UInt64 = 0x9c00_0000_0000_0000
  let operation = status & 0xfff0
  guard status & ~UInt64(0xffff) == flags, operation == 0x90 || operation == 0xa0,
    (32...52).contains(physicalBits), address >> physicalBits == 0,
    misc >> 6 == 2, misc & 63 <= 12 else { return nil }
  return address & ~UInt64(4095)
}
