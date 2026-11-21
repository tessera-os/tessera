/// A wired level-high source delegated to a supervisor APLIC MSI domain.
/// The board owner resolves the hart index (not the hart ID), reserves the
/// source and file identity, and supplies ordered 32-bit register accesses.
public struct RvWiredMSI {
  public let source, identity: UInt32
  private let target: UInt32
  private let sources: UInt32

  public init?(source: UInt32, sources: UInt32, hartIndex: UInt32, identity: UInt32, identities: UInt32) {
    guard source > 0, source <= sources, sources <= 1023, hartIndex < 1 << 14,
      identities <= 2047, identities & 63 == 63, identity > 0, identity <= identities
    else { return nil }
    self.source = source
    self.sources = sources
    self.identity = identity
    target = hartIndex << 18 | identity  // guest index zero: supervisor file only
  }

  /// Cold, exclusive domain only: never enable delivery on another owner's
  /// already active sources. Source stays masked until the local file is ready.
  public func installMasked(read: (UInt32) -> UInt32, write: (UInt32, UInt32) -> Void) -> Bool {
    let config = source * 4, dest = 0x3000 + config
    guard read(0) == 0x8000_0004, read(config) == 0 else { return false }
    for word in 0...(sources / 32) where read(0x1e00 + 4 * word) != 0 { return false }
    write(config, 6)
    write(dest, target)
    guard read(config) == 6, read(dest) == target else { return false }
    write(0, 0x104)
    return read(0) == 0x8000_0104
  }

  /// Re-sample an asserted level before enabling; an MSI consumes its APLIC
  /// pending bit. Call after servicing the device or on initial registration.
  public func unmask(write: (UInt32, UInt32) -> Void) {
    write(0x1cdc, source)
    write(0x1edc, source)
  }

  public func mask(write: (UInt32, UInt32) -> Void) { write(0x1fdc, source) }

  public var enableSelect: UInt64 { 0xc0 + 2 * UInt64(identity / 64) }
  public var enableBit: UInt64 { 1 << (identity % 64) }
}
