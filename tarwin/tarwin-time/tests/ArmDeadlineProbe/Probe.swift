import TarwinTime
import _Volatile

@_extern(c, "tarwin_clock_ticks")
private func ticks() -> UInt64
@_extern(c, "tarwin_clock_hz")
private func hz() -> UInt64
@_extern(c, "timer_probe_enable")
private func enableGroup1()
@_extern(c, "timer_probe_wait")
private func waitForIRQ()
@_extern(c, "timer_probe_status")
private func timerStatus() -> UInt64

// Pinned single-CPU virt, no firmware, GICv3 single security state. This is
// not hardware discovery. Leave every interrupt except the virtual timer off.
private func configurePPI() -> Bool {
  func reg(_ a: UInt) -> VolatileMappedRegister<UInt32> {
    VolatileMappedRegister(unsafeBitPattern: a)
  }
  let dist = reg(0x0800_0000), wake = reg(0x080a_0014)
  guard dist.load() & (1 << 6) != 0 else { return false }
  wake.store(wake.load() & ~2)
  for _ in 0..<100_000 {
    if wake.load() & 4 == 0 { break }
  }
  guard wake.load() & 4 == 0 else { return false }
  let mask: UInt32 = 1 << 27
  let group = reg(0x080b_0080)
  group.store(group.load() | mask)
  VolatileMappedRegister<UInt8>(unsafeBitPattern: 0x080b_041b).store(0x80)
  reg(0x080b_0100).store(mask)
  dist.store(dist.load() | 2)
  guard group.load() & mask != 0, reg(0x080b_0100).load() & mask != 0,
    dist.load() & 2 != 0 else { return false }
  enableGroup1()
  return true
}

@_cdecl("timer_probe")
public func test(_ state: UnsafeMutablePointer<UInt64>) -> UInt32 {
  guard configurePPI(), let clock = SystemClocks(frequency: hz(), counter: ticks()) else { return 1 }
  // First arm, cancel and replace: the original deadline must not interrupt.
  let ns: UInt64 = 8_000_000
  guard setArmVirtualDeadline(ns / 2, clock: clock), setArmVirtualDeadline(nil, clock: clock),
    timerStatus() & 1 == 0, setArmVirtualDeadline(ns, clock: clock) else { return 2 }
  waitForIRQ()
  let count = VolatileMappedRegister<UInt64>(unsafeBitPattern: UInt(bitPattern: state))
  guard count.load() == 1, state[1] == 27, let delivered = clock.read(counter: state[2]),
    delivered.monotonic >= ns, timerStatus() & 1 == 0 else { return 3 }
  guard checkSlice(frequency: hz(), counter: ticks, set: setArmVirtualCompare,
    wait: waitForIRQ, stopped: { timerStatus() & 1 == 0 }), count.load() == 2 else { return 4 }
  guard checkCoalescedIRQ(clock: clock, frequency: hz(), counter: ticks, set: setArmVirtualCompare,
    wait: waitForIRQ, stopped: { timerStatus() & 1 == 0 }), count.load() == 3 else { return 5 }
  return 0
}
