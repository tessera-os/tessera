import Tarboot
import TarwinRandomCore

/// The launcher selects this policy out of band. A boot member, fw_cfg file,
/// or TPM sample cannot assert that the machine rotates its ID on restore.
public enum QEMUGenerationPolicy {
  case unverified, rotatingDevice(pinnedPage: UInt64), readOnlyVirt11
}

public struct W1GenerationSource {
  private enum Location { case page(QEMUGenerationPage), registers }
  private let location: Location
  public static let registerBase: UInt64 = 0x090d_0000

  /// Only the validated writer-free source has a Device page. Never
  /// remap the ACPI variant's reserved normal RAM with Device attributes.
  public var readOnlyRegisterPage: UInt64? {
    if case .registers = location { return Self.registerBase }
    return nil
  }

  public init?<R: QEMUConfigReader>(policy: QEMUGenerationPolicy, reader: inout R,
    regions: UnsafeBufferPointer<FirmwareRegion>, readWord: (UInt64) -> UInt64?) {
    switch policy {
    case .unverified: return nil
    case .rotatingDevice(let pinnedPage):
      guard let page = QEMUGenerationPage.discover(&reader, pinnedPage: pinnedPage, regions: regions, readWord: readWord)
      else { return nil }
      location = .page(page)
    case .readOnlyVirt11:
      guard case .unavailable = qemuGenerationDevice(&reader) else { return nil }
      reader.select(1)
      guard reader.readByte() == 1, reader.readByte() == 0, reader.readByte() == 0, reader.readByte() == 0,
        readWord(Self.registerBase) == 0x3144_4947_4d56_5754 else { return nil }
      location = .registers
      guard current(readWord: readWord) != nil else { return nil }
    }
  }

  /// The kernel mapping, not the boot GUID, supplies each draw's epoch.
  public func current(readWord: (UInt64) -> UInt64?) -> RandomEpoch? {
    switch location {
    case .page(let page):
      guard let (lo, hi) = page.sample(readWord: readWord) else { return nil }
      return .virtualMachine(low: lo, high: hi)
    case .registers:
      let p = Self.registerBase
      for _ in 0..<3 {
        guard let version = readWord(p + 8), version != 0, let lo = readWord(p + 16),
          let hi = readWord(p + 24), let check = readWord(p + 8) else { return nil }
        if version == check { return lo | hi != 0 ? .virtualMachine(low: lo, high: hi) : nil }
      }
      return nil
    }
  }
}
