#if arch(arm64) && os(none) && hasFeature(Embedded) && hasFeature(Extern)
  @_extern(c, "tarwin_clock_ticks")
  private func ticks() -> UInt64
  @_extern(c, "tarwin_clock_compare")
  private func compare(_ value: UInt64)
  @_extern(c, "tarwin_clock_disarm")
  private func disable()

  /// On the current CPU, with IRQs masked and exclusive ownership of the
  /// accessible virtual timer. The platform configures the PPI separately.
  /// No deadline means no tick. Refusal also removes any old compare.
  public func setArmVirtualDeadline(_ ns: UInt64?, clock: SystemClocks) -> Bool {
    guard let ns else { return setArmVirtualCompare(nil) }
    let now = ticks()
    guard let target = clock.compareValue(forMonotonic: ns, counter: now) else {
      disable()
      return false
    }
    return setArmVirtualCompare(target)
  }

  /// Apply an absolute scheduling decision under the same ownership rules.
  public func setArmVirtualCompare(_ target: UInt64?) -> Bool {
    disable()
    guard let target else { return true }
    let now = ticks()
    guard target <= now || target - now <= UInt64(Int64.max) else { return false }
    compare(max(now, target))
    return true
  }
#endif
