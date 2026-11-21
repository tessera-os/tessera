#if ARM_WATCHDOG
import KCore
import TarwinArchAarch64
import TarwinBoot
import TarwinBootstrap
import _Volatile

@_extern(c, "tarwin_clock_ticks") private func ticks() -> UInt64
@_extern(c, "tarwin_clock_hz") private func frequency() -> UInt64
@_extern(c, "watchdog_probe_barrier") private func barrier()
@_extern(c, "watchdog_probe_wait") private func waitForReset()

private struct MMIO: ArmWatchdogIO {
  private func register(_ frame: ArmWatchdogFrame, _ offset: UInt32) -> VolatileMappedRegister<UInt32> {
    let base: UInt = frame == .control ? 0x0f001000 : 0x0f000000
    return .init(unsafeBitPattern: base + UInt(offset))
  }
  func read(_ frame: ArmWatchdogFrame, _ offset: UInt32) -> UInt32 {
    barrier()
    return register(frame, offset).load()
  }
  func write(_ frame: ArmWatchdogFrame, _ offset: UInt32, _ value: UInt32) {
    register(frame, offset).store(value)
    barrier()
  }
}

// Private test RAM outside the kernel, DTB and stacks; not a real boot-reason
// register. The host independently requires WS0, WS1 and a watchdog reset.
@_cdecl("watchdog_probe")
public func watchdogProbe(_ dtb: UInt) -> UInt32 {
  guard dtb & 7 == 0, (0x4000_0000...0x47ff_ffd8).contains(dtb),
    let p = UnsafeRawPointer(bitPattern: dtb) else { return 1 }
  let n = Int(UInt32(bigEndian: p.load(fromByteOffset: 4, as: UInt32.self)))
  guard n >= 40, n <= 0x4800_0000 - Int(dtb) else { return 1 }
  guard treeSupportsVirtWatchdog(WatchdogTree(bytes: .init(start: p, count: n))) else { return 2 }
  guard dtb > 0x4700_0007 || dtb + UInt(n) <= 0x4700_0000 else { return 1 }
  let cookie = VolatileMappedRegister<UInt64>(unsafeBitPattern: 0x4700_0000)
  let magic: UInt64 = 0x5744_542d_5445_5354
  let io = MMIO()
  if cookie.load() == magic {
    cookie.store(0)
    return io.read(.control, 0) == 0 ? 0 : 1
  }
  let hz = frequency(), offset = hz / 20
  var cpu = BootCPU()
  guard hz == 1_000_000_000, cookie.load() == 0,
    cpu.start(counter: ticks(), frequency: hz, initialContext: 1),
    let first = cpu.service(.poll, counter: ticks()),
    cpu.service(.add(context: 2, qos: 3), counter: ticks()) != nil,
    var w = ArmGenericWatchdog(bus: io, offset: offset, dispatch: first.counter)
  else { return 1 }
  var last = first.counter
  for _ in 0..<9 {
    while ticks() - last < offset / 3 {}
    guard let d = cpu.service(.yield, counter: ticks()), d.previous != d.next,
      w.service(dispatch: d.counter), !w.service(dispatch: d.counter) else { return 1 }
    last = d.counter
  }
  guard last - first.counter > 2 * offset else { return 1 }
  cookie.store(magic)
  barrier()
  waitForReset()
  return 1
}

private struct WatchdogTree: ByteSource {
  let bytes: UnsafeRawBufferPointer
  func byteCount() -> UInt64 { UInt64(bytes.count) }
  func byteAt(_ i: UInt64) -> UInt8 { bytes[Int(i)] }
}
#endif
