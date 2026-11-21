import TarwinArchAarch64
import TarwinLoader
import TarwinW0Verify

/// Bind the verified pair in an unpublished, exclusively owned process root.
/// The frame and `sign` are trusted kernel capabilities for this process:
/// sign in storage form with its private IA key, never with the kernel key.
/// Caller verifies/maps the signed PT_LOAD bytes first and pins their frames.
@unsafe public func bindAuthorizedQEMUImport(_ set: borrowing W1BootSet, plan: W1AddressPlan,
  tables: inout ArmUserTranslation, frame: UnsafeMutableRawBufferPointer, physical: UInt64,
  sign: (UInt64, UInt64) -> UInt64?) -> Bool {
  let p = plan.processReservation, l = plan.libraryReservation
  let base = p.lowerBound, lib = l.lowerBound
  guard !p.overlaps(l), p.upperBound <= 1 << 43, l.upperBound <= 1 << 43,
    p.upperBound - base == set.process.layout.reservationBytes,
    l.upperBound - lib == set.library.layout.reservationBytes,
    let ro = set.process.layout.relroBytes, ro.upperBound <= p.upperBound - base,
    set.library.layout.code.upperBound <= l.upperBound - lib,
    plan.sealReadOnly.lowerBound == base + ro.lowerBound,
    plan.sealReadOnly.upperBound == base + ((ro.upperBound + 16383) & ~UInt64(16383)),
    plan.libraryCode == (lib + set.library.layout.code.lowerBound)..<(lib + set.library.layout.code.upperBound),
    set.library.layout.code.contains(set.binding.entryRVA), ro.contains(set.binding.slotRVA),
    ro.upperBound - set.binding.slotRVA >= 8,
    plan.slotAddress == base + set.binding.slotRVA, plan.targetAddress == lib + set.binding.entryRVA,
    plan.storageModifier == plan.slotAddress | (UInt64(set.binding.typeTag & 0xffff) << 48)
  else { return false }
  return tables.bindPrivateImport(slot: plan.slotAddress, target: plan.targetAddress,
    modifier: plan.storageModifier, libraryCode: plan.libraryCode, relro: plan.sealReadOnly,
    frame: frame, physical: physical, sign: sign)
}
