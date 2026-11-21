import TarwinBoot

#if arch(arm64) || arch(riscv64)
  /// Scalar from RISCV_EFI_BOOT_PROTOCOL. Neither a hart index nor permission to start a CPU.
  public struct FirmwareBootHart {
    private let id: UInt64
    typealias GetID = @convention(c) (UnsafeRawPointer, UnsafeMutablePointer<UInt64>) -> UInt

    init?(_ locate: LocateProtocol) {
      var guid = (UInt64(0x4eec_6f73_ccd1_5fec), UInt64(0xbf40_b9e4_693e_9583))
      var result: UnsafeRawPointer?
      var hart = UInt64.max
      guard withUnsafeBytes(of: &guid, { locate($0.baseAddress!, nil, &result) }) == 0,
        let table = result, UInt(bitPattern: table) & 7 == 0,
        table.load(as: UInt64.self) == 0x0001_0000,
        let get = table.load(fromByteOffset: 8, as: GetID?.self),
        get(table, &hart) == 0, hart != .max else { return nil }
      id = hart
    }

    /// Use after EFI exit under exclusive boot ownership. The caller supplies the complete
    /// validated MADT/FDT inventory, not a selected subset. Only STARTED/STOPPED are final.
    public func verifiedID(in inventory: UnsafeBufferPointer<FirmwareProcessor>,
      hsmStatus: (UInt64) -> UInt64?) -> UInt64? {
      var found = false
      for i in inventory.indices {
        let hart = inventory[i].hardwareID
        guard hart != .max else { return nil }
        for j in 0..<i where inventory[j].hardwareID == hart { return nil }
        let current = hart == id
        guard hsmStatus(hart) == (current ? 0 : 1) else { return nil }
        if current { found = true }
      }
      return found ? id : nil
    }
  }
#endif
