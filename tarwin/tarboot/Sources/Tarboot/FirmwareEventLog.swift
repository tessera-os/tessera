import TarwinBoot

#if arch(arm64) || arch(riscv64) || (arch(x86_64) && (os(Windows) || TARBOOT_EFI_PE_COFF))
  // Limit both work and physical reads to ordinary firmware log storage.
  private func logView(_ base: UInt64, map: UnsafeBufferPointer<FirmwareRegion>)
    -> UnsafeRawBufferPointer?
  {
    guard base != 0, let ptr = UnsafeRawPointer(bitPattern: UInt(base)) else { return nil }
    for r in map where base >= r.base && base - r.base < r.length {
      guard r.type == 10 || r.type == 4 || r.type == 9, r.attributes & 0x2000 == 0 else {
        return nil
      }
      return UnsafeRawBufferPointer(
        start: ptr, count: Int(min(16 << 20, r.length - (base - r.base))))
    }
    return nil
  }

  public struct PendingFirmwareLog: ~Copyable {
    private let storageBase: UInt64
    private let length: Int
    private let final: UInt64
    private let baseline: UInt64
    private let format: EventLogFormat

    init?(
      base: UInt64, last: UInt64, final: UInt64,
      storage: borrowing FirmwareBootServices.LoaderPages,
      regions: UnsafeBufferPointer<FirmwareRegion>
    ) {
      guard let primary = logView(base, map: regions), last >= base,
        last - base < UInt64(primary.count),
        let fmt = EventLogFormat(primary),
        let n = fmt.primaryLength(primary, last: Int(last - base)),
        n <= storage.length, let out = UnsafeMutableRawPointer(bitPattern: UInt(storage.base)),
        let table = logView(final, map: regions), table.count >= 16,
        table.loadUnaligned(as: UInt64.self) == 1
      else { return nil }
      baseline = table.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
      out.copyMemory(from: primary.baseAddress!, byteCount: n)
      self.final = final
      format = fmt
      storageBase = storage.base
      length = n
    }

    /// After successful firmware exit. No live EFI method or protocol pointer
    /// survives in this value. The returned prefix alone is published in TBIB.
    @unsafe public consuming func finish(
      in storage: borrowing FirmwareBootServices.LoaderPages,
      regions: UnsafeBufferPointer<FirmwareRegion>
    ) -> Int? {
      guard storage.base == storageBase, UInt64(length) <= storage.length,
        let p = UnsafeMutableRawPointer(bitPattern: UInt(storageBase)),
        let table = logView(final, map: regions),
        let suffix = format.finalSuffix(
          table, baseline: baseline,
          primary: UnsafeRawBufferPointer(start: p, count: length)),
        UInt64(suffix.count) <= storage.length - UInt64(length)
      else { return nil }
      if !suffix.isEmpty {
        p.advanced(by: length).copyMemory(
          from: table.baseAddress!.advanced(by: suffix.lowerBound), byteCount: suffix.count)
      }
      return length + suffix.count
    }
  }
#endif
