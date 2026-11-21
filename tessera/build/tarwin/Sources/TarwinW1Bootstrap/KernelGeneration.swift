import TarwinArchAarch64
import TarwinW1Generation

#if hasFeature(Embedded) && hasFeature(Extern) && arch(arm64) && os(none)
  @_extern(c, "tarwin_w1_read_generation_register")
  private func readRegister(_ root: UInt64, _ va: UInt64, _ pa: UInt64,
    _ into: UnsafeMutablePointer<UInt64>) -> UInt32
#endif

/// Mapping of the independently discovered read-only device, not a cached
/// epoch. Keep the host root pinned and immutable, including its frame
/// ownership and aliases. Serialize sampling and key use against restore.
public struct W1KernelGeneration {
  public let source: W1GenerationSource
  private let root, base: UInt64

  public init?(_ source: W1GenerationSource, at virtual: UInt64, in host: inout ArmKernelTranslation) {
    guard let physical = source.readOnlyRegisterPage, host.layout == .guarded,
      host.insertReadOnlyDevice(virtual: virtual, physical: physical) else { return nil }
    self.source = source
    root = host.physicalRoot
    base = virtual
  }

  /// Use as the live word reader for import signing and guarded entry.
  /// An inactive root or an unexpected mapping has no current generation.
  public func readWord(_ physical: UInt64) -> UInt64? {
    let page = W1GenerationSource.registerBase
    guard physical >= page, physical - page < 32, physical & 7 == 0 else { return nil }
    #if hasFeature(Embedded) && hasFeature(Extern) && arch(arm64) && os(none)
      var word: UInt64 = 0
      guard readRegister(root, base + (physical - page), physical, &word) == 1 else { return nil }
      return word
    #else
      return nil
    #endif
  }
}
