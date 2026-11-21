#if arch(arm64) && os(none) && hasFeature(Embedded) && hasFeature(Extern)
  @_extern(c, "tarwin_psci_smc")
  private func smc(_ fid: UInt64, _ a: UInt64, _ b: UInt64, _ c: UInt64) -> UInt64

  /// For the platform's firmware-verified SMC conduit only, with exclusive
  /// control of online/offline transitions. An OFF result is local to this
  /// query; CPU_ON also checks PSCI's return code.
  public func armSMCCPUIsOff(_ mpidr: UInt64) -> Bool {
    guard mpidr & ~UInt64(0xff00_ffffff) == 0 else { return false }
    let version = UInt32(truncatingIfNeeded: smc(0x8400_0000, 0, 0, 0))
    return version >= 0x10001 && version < 0x80000000 && smc(0xc400_0004, mpidr, 0, 0) == 1
  }

  /// The boot owner reserves the entry point, stack and boot data until
  /// the enumerated secondary has reported its state. Accepted != online.
  public func startOffArmSMCCPU(
    _ mpidr: UInt64, bootMPIDR: UInt64, physicalEntry: UInt64, context: UInt64
  ) -> Bool {
    guard mpidr != bootMPIDR, physicalEntry != 0, physicalEntry & 3 == 0, armSMCCPUIsOff(mpidr)
    else { return false }
    return smc(0xc400_0003, mpidr, physicalEntry, context) == 0
  }
#endif
