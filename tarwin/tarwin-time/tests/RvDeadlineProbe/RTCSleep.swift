import TarwinTime
import TarwinArchRv64
import _Volatile

@_extern(c, "tarwin_rv_ticks") private func ticks() -> UInt64
@_extern(c, "timer_probe_wait") private func waitForIRQ()
@_extern(c, "timer_probe_external_enable") private func externalEnable()
@_extern(c, "timer_probe_io_fence") private func fence()

// Single-hart QEMU virt, PLIC S context 1 or S APLIC/IMSIC and RTC on IRQ 11.
// The runner verifies this exact topology and passes that DTB to the guest.
private func reg(_ at: UInt) -> VolatileMappedRegister<UInt32> {
  VolatileMappedRegister(unsafeBitPattern: at)
}

#if AIA_RTC
  @_extern(c, "tarwin_imsic_read") private func fileRead(_ select: UInt64) -> UInt64
  @_extern(c, "tarwin_imsic_write") private func fileWrite(_ select: UInt64, _ word: UInt64)

  // Dedicated cold S-mode domain and local interrupt file; the runner checks
  // firmware routing before boot. Never apply this setup to a shared domain.
  private func domainRead(_ offset: UInt32) -> UInt32 {
    fence()
    return reg(0x0d00_0000 + UInt(offset)).load()
  }
  private func domainWrite(_ offset: UInt32, _ value: UInt32) {
    reg(0x0d00_0000 + UInt(offset)).store(value)
    fence()
  }
#endif

private func rtc() -> UInt64 {
  let low = reg(0x101000).load() // latches the high word
  fence()
  return UInt64(reg(0x101004).load()) << 32 | UInt64(low)
}

// QEMU's RTC and rdtime are distinct device interfaces, both backed by
// virtual time in this fixture. This is not physical oscillator evidence.
func corroborateTimebase(_ hz: UInt32) -> BootCounterRate? {
  func stamp() -> CounterCrossStamp? {
    let a = ticks(), ns = rtc(), b = ticks()
    return CounterCrossStamp(before: a, referenceNS: ns, after: b)
  }
  for _ in 0..<4 {
    guard let a = stamp(), a.referenceNS <= .max - 40_000_000 else { return nil }
    for _ in 0..<4_000_000 {
      let ns = rtc()
      guard ns >= a.referenceNS else { return nil }
      if ns - a.referenceNS >= 40_000_000 {
        guard let b = stamp() else { return nil }
        if let checked = BootCounterRate(advertisedHz: UInt64(hz), first: a, last: b,
          minimumNS: 40_000_000, maximumErrorNS: 100_000),
          BootCounterRate(advertisedHz: UInt64(hz) * 2, first: a, last: b,
            minimumNS: 40_000_000, maximumErrorNS: 100_000) == nil { return checked }
        break
      }
    }
  }
  return nil
}

func checkRTCWake(_ hz: UInt32, state: UnsafePointer<UInt64>) -> Bool {
  var slots = InlineArray<2, TimerSlot>(repeating: TimerSlot())
  return withUnsafeMutableBytes(of: &slots) {
    let buf = $0.bindMemory(to: TimerSlot.self)
    guard var wake = OneShotTimers(storage: .init(rebasing: buf[..<1]), identity: 7, domain: .boot, wakesSystem: true),
      var deferred = OneShotTimers(storage: .init(rebasing: buf[1...]), identity: 8, domain: .boot, wakesSystem: false),
      var clock = SystemClocks(frequency: UInt64(hz), counter: ticks()),
      let armed = clock.read(counter: ticks()),
      wake.arm(deadline: armed.boot + 30_000_000, at: armed, tolerance: .strict, cookie: 1) != nil,
      deferred.arm(deadline: armed.boot + 4_000_000, at: armed, tolerance: .strict, cookie: 2) != nil
    else { return false }
    // No periodic timer. Clear any old alarm and pending RTC level before
    // enabling the only external interrupt in this dedicated context.
    reg(0x101010).store(0)
    reg(0x101014).store(1)
    reg(0x10101c).store(1)
    #if AIA_RTC
      guard let route = RvWiredMSI(source: 11, sources: 96, hartIndex: 0, identity: 65, identities: 255)
      else { return false }
      for k in 0..<4 {
        let i = UInt64(2 * k)
        guard fileRead(0x80 + i) == 0, fileRead(0xc0 + i) == 0 else { return false }
      }
      guard route.installMasked(read: domainRead, write: domainWrite) else { return false }
      fileWrite(0x72, 0)
      fileWrite(route.enableSelect, route.enableBit)
      fileWrite(0x70, 1)
      guard fileRead(0x70) == 1, fileRead(0x72) == 0,
        fileRead(route.enableSelect) == route.enableBit else { return false }
      route.unmask(write: domainWrite)
    #else
      reg(0x0c00_002c).store(1) // source 11 priority
      reg(0x0c00_2080).store(1 << 11)
      reg(0x0c20_1000).store(0)
    #endif
    fence()
    let parked = ticks(), before = rtc()
    guard let last = clock.read(counter: parked),
      case .atBoot(let deadline) = wake.nextWake(clock: clock, counter: parked, preparingSleep: true)
        .including(deferred.nextWake(clock: clock, counter: parked, preparingSleep: true)),
      deadline == armed.boot + 30_000_000, deadline > last.boot,
      deadline - last.boot <= .max - before, clock.suspend(counter: parked)
    else { return false }
    let alarm = before + (deadline - last.boot)
    reg(0x10100c).store(UInt32(alarm >> 32))
    fence()
    reg(0x101008).store(UInt32(truncatingIfNeeded: alarm))
    fence()
    reg(0x101010).store(1)
    externalEnable()
    waitForIRQ()
    let after = rtc(), counter = ticks()
    #if AIA_RTC
      let expected: UInt64 = 65
      route.mask(write: domainWrite)
      guard domainRead(0x1e00) & (1 << 11) == 0,
        fileRead(route.enableSelect - 0x40) & route.enableBit == 0 else { return false }
      reg(0x101010).store(0)
      reg(0x10101c).store(1)
      fence()
    #else
      let expected: UInt64 = 11
    #endif
    guard state[0] == 4, state[2] == expected, reg(0x101010).load() == 0,
      after >= alarm, clock.resume(counter: counter, sleepNS: after - before),
      let resumed = clock.read(counter: counter), resumed.monotonic == last.monotonic,
      resumed.boot >= deadline, wake.takeDue(at: resumed) == 1, deferred.takeDue(at: resumed) == 2,
      wake.takeDue(at: resumed) == nil, deferred.takeDue(at: resumed) == nil else { return false }
    #if AIA_RTC
      var count = state[0]
      return checkIRQPort(vector: route.identity, mask: { route.mask(write: domainWrite) },
        unmask: { route.unmask(write: domainWrite) }, masked: { domainRead(0x1e00) & (1 << 11) == 0 },
        raise: {
          reg(0x10100c).store(0)
          fence()
          reg(0x101008).store(0)  // already due
          fence()
          reg(0x101010).store(1)
          fence()
        }, lower: {
          reg(0x101010).store(0)
          reg(0x10101c).store(1)
          fence()
        }, pendingWhileMasked: {
          domainRead(0x1c00) & (1 << 11) != 0 && domainRead(0x1e00) & (1 << 11) == 0
            && fileRead(route.enableSelect - 0x40) & route.enableBit == 0
        }, wait: {
          externalEnable()
          waitForIRQ()
          count += 1
          return state[0] == count && state[2] == UInt64(route.identity)
        }, now: { clock.read(counter: ticks())?.monotonic })
    #else
      return true
    #endif
  }
}
