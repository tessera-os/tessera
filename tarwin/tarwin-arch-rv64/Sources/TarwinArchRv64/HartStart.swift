#if arch(riscv64) && os(none) && hasFeature(Embedded) && hasFeature(Extern)
  @_extern(c, "tarwin_sbi_hsm_present") private func present() -> UInt64
  @_extern(c, "tarwin_sbi_hsm_status") private func state(_ hart: UInt64) -> UInt64
  @_extern(c, "tarwin_sbi_hsm_start")
  private func start(_ hart: UInt64, _ physicalEntry: UInt64, _ opaque: UInt64) -> Int64

  public func rvHartStatus(_ hart: UInt64) -> UInt64? {
    guard hart != .max, present() == 1 else { return nil }
    let status = state(hart)
    return status <= 6 ? status : nil
  }

  public func rvHartIsStopped(_ hart: UInt64) -> Bool {
    rvHartStatus(hart) == 1
  }

  /// The exclusive boot owner supplies a firmware-enumerated hart, a
  /// physical S-mode reset veneer and pinned release/acquire boot data. A
  /// successful SBI call means accepted, not online: await a handshake on
  /// the secondary's own stack before exposing it to the scheduler.
  public func startStoppedRvHart(
    _ hart: UInt64, bootHart: UInt64, physicalEntry: UInt64, opaque: UInt64
  ) -> Bool {
    guard hart != bootHart, physicalEntry != 0, physicalEntry & 3 == 0,
      rvHartIsStopped(hart) else { return false }
    return start(hart, physicalEntry, opaque) == 0
  }
#endif
