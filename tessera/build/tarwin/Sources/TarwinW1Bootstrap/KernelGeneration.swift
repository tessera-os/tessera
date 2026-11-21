import TarwinArchAarch64
import TarwinRandomCore
import TarwinW1Generation
#if TARWIN_NON_RESTORABLE_DEBUG
  import TarwinKernelRandom
#endif

#if hasFeature(Embedded) && hasFeature(Extern) && arch(arm64) && os(none)
  @_extern(c, "tarwin_w1_read_generation_register")
  private func readRegister(_ root: UInt64, _ va: UInt64, _ pa: UInt64,
    _ into: UnsafeMutablePointer<UInt64>) -> UInt32
  #if TARWIN_NON_RESTORABLE_DEBUG
    @_extern(c, "tarwin_w1_active_host_root") private func activeRoot(_ expected: UInt64) -> UInt32
  #endif
#endif

/// The guarded host root owns either the discovered register mapping or an
/// explicitly non-restorable debug launch. Keep that root pinned; serialize
/// live generation sampling and key use against restore.
public struct W1KernelGeneration {
  private enum Source {
    case device(W1GenerationSource)
    #if TARWIN_NON_RESTORABLE_DEBUG
      case nonRestorable(RandomEpoch)
    #endif
  }
  private let source: Source
  private let root, base: UInt64

  public init?(_ source: W1GenerationSource, at virtual: UInt64, in host: inout ArmKernelTranslation) {
    guard let physical = source.readOnlyRegisterPage, host.layout == .guarded,
      host.insertReadOnlyDevice(virtual: virtual, physical: physical) else { return nil }
    self.source = .device(source)
    root = host.physicalRoot
    base = virtual
  }

  #if TARWIN_NON_RESTORABLE_DEBUG
  /// No register page exists in this profile. Bind only a checked cold
  /// launch, never an epoch reconstructed from user storage or wire words.
  public init?(nonRestorable launch: borrowing FixedDebugRandomLaunch, in host: borrowing ArmKernelTranslation) {
    guard host.layout == .guarded, case .fixedDebugQEMU = launch.generation else { return nil }
    source = .nonRestorable(launch.generation)
    root = host.physicalRoot
    base = 0
  }
  #endif

  /// No caller-supplied word reader on the key-use path. Refuse if the
  /// expected host root differs from the one that owns this aperture.
  public func current(in host: borrowing ArmFinishedKernelRoot) -> RandomEpoch? {
    guard host.layout == .guarded, host.physical == root else { return nil }
    switch source {
    case .device(let device): return device.current(readWord: { readWord($0) })
    #if TARWIN_NON_RESTORABLE_DEBUG
    case .nonRestorable(let epoch):
      #if hasFeature(Embedded) && hasFeature(Extern) && arch(arm64) && os(none)
        return activeRoot(root) == 1 ? epoch : nil
      #else
        return nil
      #endif
    #endif
    }
  }

  func readWord(_ physical: UInt64) -> UInt64? {
    let page = W1GenerationSource.registerBase
    guard case .device = source, physical >= page, physical - page < 32, physical & 7 == 0 else { return nil }
    #if hasFeature(Embedded) && hasFeature(Extern) && arch(arm64) && os(none)
      var word: UInt64 = 0
      guard readRegister(root, base + (physical - page), physical, &word) == 1 else { return nil }
      return word
    #else
      return nil
    #endif
  }
}
