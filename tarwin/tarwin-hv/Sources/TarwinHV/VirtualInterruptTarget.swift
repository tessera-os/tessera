/// Software-backed Group 1 SGI/PPI/SPI. Never accepts a physical INTID,
/// sets the HW bit, or programs an occupied list register.
public struct ArmVirtualIRQ {
  public let listValue: UInt64
  public init?(interrupt: UInt32, priority: UInt8) {
    guard interrupt < 1020 else { return nil }
    listValue = (UInt64(1) << 62) | (UInt64(1) << 60) | (UInt64(priority) << 48) | UInt64(interrupt)
  }

  /// Caller owns the stopped vCPU and its LR bank throughout the update.
  public func inject(count: Int, empty: UInt64, write: (Int, UInt64) -> Bool) -> Bool {
    guard (1...16).contains(count) else { return false }
    let available = empty & ((UInt64(1) << count) - 1)
    guard available != 0 else { return false }
    return write(available.trailingZeroBitCount, listValue)
  }
}

/// One guest interrupt file within one platform-reserved hart aperture.
/// File zero belongs to HS. The host, not the guest, supplies the aperture
/// and the count of available guest files from hardware discovery.
public struct IMSICGuestTarget {
  public let doorbell: UInt64
  public let index: UInt8
  private let lastID: UInt16
  public init?(hartBase: UInt64, bytes: UInt64, files: UInt8, index: UInt8, lastID: UInt16) {
    guard hartBase & 4095 == 0, bytes & 4095 == 0, bytes > 0, bytes - 1 <= UInt64.max - hartBase,
      files > 0, files <= 63, index > 0, index <= files,
      UInt64(files) + 1 <= bytes / 4096, (63...2047).contains(lastID), lastID % 64 == 63
    else { return nil }
    self.doorbell = hartBase + UInt64(index) * 4096
    self.index = index
    self.lastID = lastID
  }
  /// Little-endian SETIPNUM_LE, 32-bit device store. Caller holds the
  /// assignment until the posted message is drained or the file reset.
  public func post(_ id: UInt16, write: (UInt64, UInt32) -> Bool) -> Bool {
    guard id > 0 && id <= lastID else { return false }
    return write(doorbell, UInt32(id))
  }
}
