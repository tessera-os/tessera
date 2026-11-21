import KCore
import TarwinArchAarch64
import TarwinBoot
import TarwinTime
import _Volatile

@_extern(c, "tarwin_clock_ticks") private func ticks() -> UInt64
@_extern(c, "tarwin_clock_hz") private func hz() -> UInt64

private struct Tree: ByteSource {
  let bytes: UnsafeRawBufferPointer
  func byteCount() -> UInt64 { UInt64(bytes.count) }
  func byteAt(_ i: UInt64) -> UInt8 { bytes[Int(i)] }
}

private func calibratePL031() -> BootCounterRate? {
  let clock = VolatileMappedRegister<UInt32>(unsafeBitPattern: 0x0901_0000)
  let frequency = hz()
  guard frequency > 0, frequency <= UInt32.max else { return nil }
  // RTC_DR quantizes to seconds. Bracket actual transitions, not reads of
  // the same seconds register arbitrarily far from the second boundary.
  func edge() -> CounterCrossStamp? {
    var before = ticks()
    let origin = before, seconds = clock.load()
    guard seconds != .max else { return nil }
    while true {
      let t = ticks(), s = clock.load()
      if s != seconds {
        guard s == seconds + 1 else { return nil }
        return CounterCrossStamp(before: before, referenceNS: UInt64(s) * 1_000_000_000, after: ticks())
      }
      if t < origin || t - origin > frequency * 2 { return nil }
      before = t
    }
  }
  guard let a = edge(), let b = edge() else { return nil }
  return BootCounterRate(advertisedHz: frequency, first: a, last: b, minimumNS: 1_000_000_000,
    maximumErrorNS: 2_000_000)
}

@_cdecl("arm_smp_probe")
public func probe(_ dtb: UInt, _ mpidr: UInt64) -> UInt32 {
  guard dtb & 7 == 0, (0x4000_0000...0x47ff_ffd8).contains(dtb),
    let ptr = UnsafeRawPointer(bitPattern: dtb) else { return 0 }
  let n = Int(UInt32(bigEndian: ptr.load(fromByteOffset: 4, as: UInt32.self)))
  guard n >= 40, n <= 0x4800_0000 - Int(dtb) else { return 0 }
  var ids = InlineArray<2, FirmwareProcessor>(repeating: .empty)
  let tree = Tree(bytes: .init(start: ptr, count: n))
  guard treeSupportsEL2PSCI(tree) else { return 2 }
  let count = withUnsafeMutableBytes(of: &ids) {
    treeProcessors(tree, family: .arm64,
      into: $0.bindMemory(to: FirmwareProcessor.self))
  }
  let boot = mpidr & 0xff00_ffffff, a = ids[0].hardwareID, b = ids[1].hardwareID
  guard count == 2, a == boot || b == boot else { return 0 }
  guard ids[0].usesPSCI && ids[1].usesPSCI else { return 2 }
  guard let rate = calibratePL031() else { return 0 }
  return checkTwoCPUs(boot: boot, peer: a == boot ? b : a, rate: rate, stopped: armSMCCPUIsOff,
    start: startOffArmSMCCPU) ? 1 : 0
}
