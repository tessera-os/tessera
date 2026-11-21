#if TARWIN_NON_RESTORABLE_DEBUG && hasFeature(Embedded) && hasFeature(Extern) && arch(arm64) && os(none)
import TarwinBoot
import TarwinW0Verify

extension W1ColdVerifiedSet {
  /// Call once under exclusive ownership of the immutable map, RAM and TPM.
  /// Return the pinned log including the one new record, never on failure.
  @unsafe func measureFirstInit<P: TpmPort>(layout k: W1ColdLogLayout,
    port: inout P) -> UnsafeRawBufferPointer? {
    guard let src = UnsafeRawPointer(bitPattern: UInt(k.source.lowerBound)),
      let dst = UnsafeMutableRawPointer(bitPattern: UInt(k.storage.lowerBound)) else { return nil }
    let prefix = UnsafeRawBufferPointer(start: src, count: Int(boot.logSize))
    dst.copyMemory(from: src, byteCount: prefix.count)
    let copy = UnsafeMutableRawBufferPointer(start: dst, count: Int(k.storage.count))
    guard let previous = confirmedColdPCR10(.init(start: dst, count: prefix.count),
      archive: set.archiveSHA256, configuration: set.configurationSHA256,
      matchesPCR: { matchesBootPCR(&port, index: $0, expected: $1) }) else { return nil }
    var state = MeasurementLog(used: boot.logSize, stopped: false)
    guard measureAuthorizedQEMUInit(set, in: archive, previousPCR10: previous,
      port: &port, state: &state, log: copy), !state.stopped else { return nil }
    return UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(copy)[..<Int(state.used)])
  }
}
#endif
