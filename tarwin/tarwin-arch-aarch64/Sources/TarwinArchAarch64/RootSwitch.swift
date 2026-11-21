#if hasFeature(Embedded) && hasFeature(Extern) && arch(arm64) && os(none)
  @_extern(c, "tarwin_w1_switch_user_root")
  private func switchDirect(_ user: UInt64, _ host: UInt64) -> UInt32
  @_extern(c, "tarwin_w1_switch_guarded_root")
  private func switchGuarded(_ user: UInt64, _ host: UInt64) -> UInt32
  @_extern(c, "tarwin_w1_check_host_write")
  private func checkHostWrite(_ root: UInt64, _ virtual: UInt64, _ physical: UInt64) -> UInt32
#endif

extension ArmFinishedKernelRoot {
  /// Check the live EL2 translation of an upper-half 16 KiB frame before
  /// the first write. Keep this immutable root active on this CPU through
  /// use. This checks one host VA, not aliases, DMA or process ownership.
  @unsafe public func permitsLocalWrite(virtual: UInt64, physical frame: UInt64) -> Bool {
    guard virtual >= 0xffff_8000_0000_0000, frame != 0, frame < 1 << 48,
      (virtual | frame) & 16383 == 0 else { return false }
    #if hasFeature(Embedded) && hasFeature(Extern) && arch(arm64) && os(none)
      return checkHostWrite(physical, virtual, frame) == 1
    #else
      return false
    #endif
  }
}

/// Boot CPU with exclusive ownership of both pinned, immutable roots.
/// The host root must already be active with its exact permission bank.
/// Keep interrupts masked and install the new CPU context before release.
/// No EL0 entry, process-key/GCSPR installation or root retirement here.
@unsafe public func switchArmUserRoot(
  _ user: borrowing ArmFinishedUserRoot, host: borrowing ArmFinishedKernelRoot
) -> Bool {
  guard user.physical != host.physical, user.layout == host.layout else { return false }
  #if hasFeature(Embedded) && hasFeature(Extern) && arch(arm64) && os(none)
    switch user.layout {
    case .direct: return switchDirect(user.physical, host.physical) == 1
    case .guarded: return switchGuarded(user.physical, host.physical) == 1
    }
  #else
    return false
  #endif
}
