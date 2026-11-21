#if arch(riscv64) && os(none) && hasFeature(Embedded) && hasFeature(Extern)
  @_extern(c, "tarwin_rv_ticks")
  private func ticks() -> UInt64
  @_extern(c, "tarwin_rv_compare")
  private func compare(_ value: UInt64)
  @_extern(c, "tarwin_rv_disarm")
  private func disable()

  /// Call only on the owning hart after firmware advertised Sstc and Zicntr
  /// and M-mode enabled S-mode time/STCE and STIP delegation. SIE must be
  /// clear. An absent or mismatched frequency refuses without CSR access.
  public func setRvSstcDeadline(_ ns: UInt64?, clock: SystemClocks, hartHz: UInt32?) -> Bool {
    guard let hartHz, UInt64(hartHz) == clock.frequency else { return false }
    guard let ns else { return setRvSstcCompare(nil, hartHz: hartHz) }
    guard let target = clock.compareValue(forMonotonic: ns, counter: ticks()) else {
      disable()
      return false
    }
    return setRvSstcCompare(target, hartHz: hartHz)
  }

  /// Apply an absolute scheduling decision on a firmware-admitted hart.
  public func setRvSstcCompare(_ target: UInt64?, hartHz: UInt32?) -> Bool {
    guard let hartHz, hartHz != 0 else { return false }
    disable()
    guard let target else { return true }
    guard target != .max else { return false }
    compare(target)
    return true
  }
#endif
