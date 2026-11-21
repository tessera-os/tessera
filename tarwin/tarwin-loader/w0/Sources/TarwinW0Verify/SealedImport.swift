import TarwinLoader

extension W1BootSet {
  /// Stage the x64/RV64 eager slot directly from the authorized image into
  /// its exclusive, unpublished, DMA-inaccessible physical frame. The
  /// caller must seal the whole RELRO mapping RO/NX with no writable aliases,
  /// verify the actual code pages and install live CFI before publishing.
  /// No page table is changed and no pointer is accepted from user space.
  public func prepareCFIImportPage(plan: W1AddressPlan, at pageVA: UInt64,
    frame: UnsafeMutableRawBufferPointer) -> Bool
  {
    let page = imagePage(machine)
    guard page == 4096, plan.machine == machine, pageVA == plan.slotAddress & ~(page - 1),
      let r = process.layout.relroBytes, let f = process.layout.relroFileBytes,
      UInt64(f.count) == r.upperBound - r.lowerBound,
      binding.slotRVA & 7 == 0, r.contains(binding.slotRVA), r.upperBound - binding.slotRVA >= 8,
      library.layout.code.contains(binding.entryRVA), plan.libraryCode.contains(plan.targetAddress),
      plan.processReservation.lowerBound + binding.slotRVA == plan.slotAddress,
      plan.libraryReservation.lowerBound + binding.entryRVA == plan.targetAddress,
      plan.slotFormat == W1SlotFormat.select(machine: machine, slot: plan.slotAddress, tag: binding.typeTag),
      plan.sealReadOnly.contains(pageVA), plan.sealReadOnly.upperBound - pageVA >= page
    else { return false }
    return stageSlot(immutable: .init(rebasing: process.bytes[f]),
      offset: Int(binding.slotRVA - r.lowerBound), target: plan.targetAddress, frame: frame)
  }
}

// The immutable segment starts on a page boundary. All validation precedes
// the first write; a failed preparation leaves the frame unchanged.
func stageSlot(immutable: UnsafeRawBufferPointer, offset: Int, target: UInt64,
  frame: UnsafeMutableRawBufferPointer) -> Bool
{
  guard frame.count == 4096, offset >= 0, offset & 7 == 0, offset <= immutable.count - 8,
    immutable.loadUnaligned(fromByteOffset: offset, as: UInt64.self) == 0,
    target & 15 == 0, imageWindow.contains(target)
  else { return false }
  let first = offset & ~4095
  let count = min(4096, immutable.count - first)
  for i in 0..<count { frame[i] = immutable[first + i] }
  for i in count..<4096 { frame[i] = 0 }
  let slot = offset - first
  for i in 0..<8 { frame[slot + i] = UInt8(truncatingIfNeeded: target >> (i * 8)) }
  return true
}
