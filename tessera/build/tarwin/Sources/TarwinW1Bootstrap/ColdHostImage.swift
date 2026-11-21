import TarwinArchAarch64
import TarwinLoader
import TarwinW0Verify

extension W1ColdHostPages {
  /// The debug EFI placement uses the first 2^18 one-MiB slots. Use the
  /// TBIB virtual base only within that window; never follow its physical
  /// kernel pointer to find code. This profile admits no kernel relocations.
  static let kernelBytes = 1 << 20
  static let kernelStart: UInt64 = 0xffff_8000_0000_0000

  /// The copy immediately follows this host reservation. It is exclusive
  /// normal RAM and is never part of the child pool. On any failure discard
  /// the entire unpublished root and copy; never complete or retry it.
  @unsafe mutating func stageKernel(_ set: borrowing W1BootSet,
    archive: UnsafeRawBufferPointer, virtual: UInt64, physical: UInt64,
    copy: UnsafeMutableRawBufferPointer, cleanToPoU: (UnsafeRawBufferPointer) -> Bool) -> UInt64? {
    let span = UInt64(Self.kernelBytes), page = UInt64(Self.page)
    let kernel = set.kernel, bytes = kernel.bytes, headers = kernel.image.programHeaders
    guard set.machine == ElfMachine.aarch64, virtual >= Self.kernelStart,
      virtual - Self.kernelStart < span << 18, virtual & (span - 1) == 0,
      physical == tables.tableReservation.upperBound + 5 * page, physical <= (1 << 48) - span,
      copy.count == Self.kernelBytes, let destination = copy.baseAddress, let source = bytes.baseAddress,
      UInt(bitPattern: destination) & 7 == 0, exactMember(bytes, in: archive, at: kernel.range, excluding: copy),
      kernel.image.entry < span, headers.lowerBound >= 64, headers.upperBound <= bytes.count,
      headers.count % 56 == 0 else { return nil }
    func small(_ i: Int) -> UInt32 { bytes.loadUnaligned(fromByteOffset: i, as: UInt32.self).littleEndian }
    func wide(_ i: Int) -> UInt64 { bytes.loadUnaligned(fromByteOffset: i, as: UInt64.self).littleEndian }
    var entryMapped = false
    for at in stride(from: headers.lowerBound, to: headers.upperBound, by: 56) where small(at) == 1 {
      let offset = wide(at + 8), rva = wide(at + 16), n = wide(at + 32), flags = small(at + 4)
      guard flags == 4 || flags == 5, n != 0, n == wide(at + 40),
        (rva | offset) & (page - 1) == 0, imageContains(span, rva, n),
        imageContains(UInt64(bytes.count), offset, n) else { return nil }
      let rx = flags == 5
      if rx && (rva..<rva + n).contains(kernel.image.entry) { entryMapped = true }
      var i: UInt64 = 0
      while i < n {
        let start = Int(rva + i)
        let frame = UnsafeMutableRawBufferPointer(rebasing: copy[start..<start + Self.page])
        let used = Int(min(page, n - i))
        frame.baseAddress!.copyMemory(from: source + Int(offset + i), byteCount: used)
        frame[used...].initializeMemory(as: UInt8.self, repeating: 0)
        guard (!rx || cleanToPoU(.init(frame))),
          tables.insert(virtual: virtual + rva + i, physical: physical + rva + i,
            write: false, execute: rx) else { return nil }
        i += page
      }
    }
    return entryMapped ? virtual + kernel.image.entry : nil
  }
}
