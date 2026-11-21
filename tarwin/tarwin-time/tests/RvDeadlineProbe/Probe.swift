import KCore
import TarwinBoot
import TarwinArchRv64
import TarwinTime

@_extern(c, "tarwin_rv_ticks")
private func ticks() -> UInt64
@_extern(c, "timer_probe_wait")
private func waitForIRQ()
@_extern(c, "timer_probe_idle")
private func idle() -> UInt64

private struct Tree: ByteSource {
  let bytes: UnsafeRawBufferPointer
  func byteCount() -> UInt64 { UInt64(bytes.count) }
  func byteAt(_ i: UInt64) -> UInt8 { bytes[Int(i)] }
}

@_cdecl("rv_timer_probe")
public func test(_ hart: UInt64, _ dtb: UInt, _ state: UnsafePointer<UInt64>) -> UInt32 {
  // This test pins 128 MiB at 0x80000000. Check the header before using its
  // total length; never manufacture a large readable range past guest RAM.
  guard dtb & 7 == 0, (0x80000000...0x87ffffd8).contains(dtb),
    let p = UnsafeRawPointer(bitPattern: dtb) else { return 2 }
  let n = Int(UInt32(bigEndian: p.load(fromByteOffset: 4, as: UInt32.self)))
  guard n >= 40, n <= 0x88000000 - Int(dtb) else { return 2 }
  var cpus = InlineArray<2, FirmwareProcessor>(repeating: .empty)
  let count = withUnsafeMutableBytes(of: &cpus) {
    treeProcessors(Tree(bytes: .init(start: p, count: n)), family: .rv64, into: $0.bindMemory(to: FirmwareProcessor.self))
  }
  if count == 2 {
    #if AIA_RTC
    return 6
    #else
    let a = cpus[0], b = cpus[1]
    guard a.hardwareID == hart || b.hardwareID == hart, let hz = a.sstcFrequency,
      b.sstcFrequency == hz, let rate = corroborateTimebase(hz) else { return 2 }
    return checkTwoCPUs(boot: hart, peer: a.hardwareID == hart ? b.hardwareID : a.hardwareID,
      rate: rate, stopped: rvHartIsStopped, start: startStoppedRvHart) ? 3 : 2
    #endif
  }
  let cpu = cpus[0]
  guard count == 1, cpu.hardwareID == hart else { return 2 }
  #if AIA_RTC
    guard cpu.supervisorAIA else { return 5 }
    guard hart == 0, treeSupportsVirtSupervisorRTC(Tree(bytes: .init(start: p, count: n)))
    else { return 6 }
  #endif
  guard let hz = cpu.sstcFrequency else {
    guard let unused = SystemClocks(frequency: 1, counter: 0),
      !setRvSstcDeadline(1, clock: unused, hartHz: nil) else { return 2 }
    return 1
  }
  let ns: UInt64 = 8_000_000
  guard let rate = corroborateTimebase(hz) else { return 4 }
  guard let clock = SystemClocks(frequency: rate.frequency, counter: ticks()),
    setRvSstcDeadline(ns / 2, clock: clock, hartHz: hz),
    setRvSstcDeadline(nil, clock: clock, hartHz: hz), idle() == 1,
    setRvSstcDeadline(ns, clock: clock, hartHz: hz) else { return 2 }
  waitForIRQ()
  guard state[0] == 1, let delivered = clock.read(counter: state[1]),
    delivered.monotonic >= ns, idle() == 1 else { return 2 }
  guard checkSlice(frequency: UInt64(hz), counter: ticks,
    set: { setRvSstcCompare($0, hartHz: hz) }, wait: waitForIRQ,
    stopped: { idle() == 1 }), state[0] == 2 else { return 2 }
  guard checkCoalescedIRQ(clock: clock, frequency: UInt64(hz), counter: ticks, set: { setRvSstcCompare($0, hartHz: hz) },
    wait: waitForIRQ, stopped: { idle() == 1 }), state[0] == 3 else { return 2 }
  return checkRTCWake(hz, state: state) && idle() == 1 ? 0 : 2
}
