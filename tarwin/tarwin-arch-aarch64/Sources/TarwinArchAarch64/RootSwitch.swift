#if hasFeature(Embedded) && hasFeature(Extern) && arch(arm64) && os(none)
  @_extern(c, "tarwin_w1_switch_user_root")
  private func switchDirect(_ user: UInt64, _ host: UInt64) -> UInt32
  @_extern(c, "tarwin_w1_switch_guarded_root")
  private func switchGuarded(_ user: UInt64, _ host: UInt64) -> UInt32
#endif

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
