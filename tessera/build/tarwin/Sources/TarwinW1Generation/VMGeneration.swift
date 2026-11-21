import Tarboot
import TarwinRandomCore

/// The launcher selects this policy out of band. A boot member, fw_cfg file,
/// or TPM sample cannot assert that the machine rotates its ID on restore.
public enum QEMUGenerationPolicy {
  case unverified, rotatingDevice(pinnedPage: UInt64)
}

public struct W1GenerationSource {
  private let page: QEMUGenerationPage
  public var physical: UInt64 { page.physical }

  public init?<R: QEMUConfigReader>(policy: QEMUGenerationPolicy, reader: inout R,
    regions: UnsafeBufferPointer<FirmwareRegion>, readWord: (UInt64) -> UInt64?) {
    guard case .rotatingDevice(let pinnedPage) = policy,
      let live = QEMUGenerationPage.discover(&reader, pinnedPage: pinnedPage, regions: regions, readWord: readWord)
    else { return nil }
    page = live
  }

  /// The kernel mapping, not the boot GUID, supplies each draw's epoch.
  public func current(readWord: (UInt64) -> UInt64?) -> RandomEpoch? {
    guard let (lo, hi) = page.sample(readWord: readWord) else { return nil }
    return .virtualMachine(low: lo, high: hi)
  }
}
