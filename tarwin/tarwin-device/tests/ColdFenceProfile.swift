// Compile-only intake specialization. Reads are opaque ordered platform calls;
// no constant fixture can fold away the table walk or its failure cases.
import TarwinIO

public struct FenceProfileReader: VirtBootFenceReadBus {
  public let load: @convention(c) (UInt32, UInt64, UnsafeMutablePointer<UInt64>) -> UInt32
  private func word(_ width: UInt32, _ address: UInt64) -> UInt64? {
    var value: UInt64 = 0
    return load(width, address, &value) == 0 ? value : nil
  }
  public func read8(_ p: UInt64) -> UInt8? { word(8, p).map { UInt8(truncatingIfNeeded: $0) } }
  public func read32(_ p: UInt64) -> UInt32? { word(32, p).map { UInt32(truncatingIfNeeded: $0) } }
  public func read64(_ p: UInt64) -> UInt64? { word(64, p) }
  public func fwConfigWord(_ selector: UInt16) -> UInt32? {
    word(0, UInt64(selector)).map { UInt32(truncatingIfNeeded: $0) }
  }
}

public func profileColdFenceIntake(
  _ table: UInt64, _ commands: UInt64, _ protected: UnsafeBufferPointer<DeviceRange>,
  _ reader: inout FenceProfileReader
) -> VirtBootContinuityResult {
  checkVirtBootDMAContinuity(table: table, commands: commands, protected: protected, bus: &reader)
}
