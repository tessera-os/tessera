import TarwinObject
import TarwinSync

extension HandleReadView {
  /// Use the epoch domain that guards this table's tombstones and retired
  /// object storage. An acquired object reference survives the read epoch.
  public func pin(_ name: UInt64, kind: UInt32, need: UInt64, in domain: borrowing EpochDomain)
    -> PinResult
  {
    domain.withRead { pinWithinEpoch(name, kind: kind, need: need) }
  }
}
