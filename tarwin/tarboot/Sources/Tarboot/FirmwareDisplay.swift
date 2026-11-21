import TarwinBoot

#if arch(arm64) || arch(riscv64) || (arch(x86_64) && (os(Windows) || TARBOOT_EFI_PE_COFF))
  public struct FirmwareDisplay {
    public let base: UInt64
    public let mode: DisplayMode

    // Only pointers returned by live firmware GOP are dereferenced here. Copy
    // scalars only: no protocol, method or mode-table pointer survives exit.
    static func current(_ locate: LocateProtocol) -> FirmwareDisplay? {
      var id = (UInt64(0x4a38_23dc_9042_a9de), UInt64(0x6a51_80d0_de7a_fb96))
      var gop: UnsafeRawPointer?
      guard withUnsafeBytes(of: &id, { locate($0.baseAddress!, nil, &gop) }) == 0,
        let gop, let m = gop.load(fromByteOffset: 24, as: UnsafeRawPointer?.self),
        m.load(fromByteOffset: 4, as: UInt32.self) < m.load(as: UInt32.self),
        m.load(fromByteOffset: 16, as: UInt.self) >= 36,
        let info = m.load(fromByteOffset: 8, as: UnsafeRawPointer?.self),
        info.load(as: UInt32.self) == 0,
        let mode = DisplayMode(width: info.load(fromByteOffset: 4, as: UInt32.self),
          height: info.load(fromByteOffset: 8, as: UInt32.self),
          stride: info.load(fromByteOffset: 32, as: UInt32.self),
          format: info.load(fromByteOffset: 12, as: UInt32.self),
          capacity: m.load(fromByteOffset: 32, as: UInt64.self))
      else { return nil }
      let base = m.load(fromByteOffset: 24, as: UInt64.self)
      guard base != 0, base & 3 == 0, base <= UInt64.max - UInt64(mode.byteCount) else { return nil }
      return FirmwareDisplay(base: base, mode: mode)
    }
  }
#endif
