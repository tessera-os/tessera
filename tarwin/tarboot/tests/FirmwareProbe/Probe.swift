// EFI diagnostic, not tarboot or a Tarwin kernel. The dedicated QEMU instance
// powers off only after successful ExitBootServices and inspection of the returned map.
import Tarboot
import TarwinBootstrap
import TarwinMM

private typealias Output = @convention(c) (UnsafeRawPointer, UnsafePointer<UInt16>) -> UInt
private typealias Reset = @convention(c) (UInt32, UInt, UInt, UnsafeRawPointer?) -> Void
nonisolated(unsafe) private var storage = InlineArray<4096, UInt64>(repeating: 0)
nonisolated(unsafe) private var records = InlineArray<512, FirmwareRegion>(repeating: .empty)
nonisolated(unsafe) private var cpu = BootCPU()

@_cdecl("efi_main")
public func efiMain(_ image: UnsafeRawPointer?, _ system: UnsafeRawPointer?) -> UInt {
  let unsupported = (UInt(1) << 63) | 3
  // Only tables owned by firmware during EFI image entry; validate before field reads.
  guard let image, let system,
    FirmwareBootServices.valid(system, signature: 0x5453_5953_2049_4249, minimum: 120),
    let runtime = system.load(fromByteOffset: 88, as: UnsafeRawPointer?.self),
    FirmwareBootServices.valid(runtime, signature: 0x5652_4553_544e_5552, minimum: 112),
    let shutdown = runtime.load(fromByteOffset: 104, as: Reset?.self),
    let console = system.load(fromByteOffset: 64, as: UnsafeRawPointer?.self),
    let output = console.load(fromByteOffset: 8, as: Output?.self)
  else { return unsupported }
  let message: StaticString = "TARWIN-FIRMWARE-EXIT-TEST\r\n"
  for i in 0..<message.utf8CodeUnitCount {
    var character = (UInt16(message.utf8Start[i]), UInt16(0))
    _ = withUnsafeBytes(of: &character) {
      output(console, $0.bindMemory(to: UInt16.self).baseAddress!)
    }
  }
  // The two static arrays are disjoint, initialized, naturally aligned and exclusive.
  let done = withUnsafeMutableBytes(of: &storage) { raw in
    withUnsafeMutableBytes(of: &records) { bytes in
      var buffer = bytes.bindMemory(to: FirmwareRegion.self)
      #if arch(arm64)
        let pageSize: UInt64 = 16384
      #else
        let pageSize: UInt64 = 4096
      #endif
      guard let boot = FirmwareBootServices(image: image, system: system),
        let owned = boot.reserveLoaderPages(UInt(2 * 64 * pageSize / 4096 - 1)),
        case .exited(let n) = boot.finish(map: raw, into: &buffer)
      else { return false }
      var usable = false
      var runtime = false
      var covered = false
      for i in 0..<n {
        let kind = buffer[i].bootMapKind(afterExit: true)
        usable = usable || kind == 0
        runtime = runtime || kind == 2 || kind == 3
        let r = buffer[i]
        if r.type == 2, kind == 1, r.attributes >> 63 == 0, owned.base >= r.base,
          owned.base - r.base < r.length, owned.length <= r.length - (owned.base - r.base)
        {
          covered = true
        }
      }
      return usable && runtime && covered
        && checkPage(base: owned.base, length: owned.length, pageSize: pageSize)
        && runBootCPU(UInt64(n))
    }
  }
  if done { shutdown(2, 0, 0, nil) }  // EfiResetShutdown; still in physical addressing mode.
  // Failure after a partial firmware shutdown is terminal. Never return into boot services.
  while true {}
}

// Only call for the dedicated firmware allocation in the identity map.
// Never use arbitrary RAM found by scanning the map. No CPU or device shares it.
private func checkPage(base: UInt64, length: UInt64, pageSize: UInt64) -> Bool {
  guard var arena = arenaFromReservation(base: base, length: length, pageSize: pageSize) else {
    return false
  }
  let page = takePages(&arena, order: 0)
  guard page.ok, let bytes = UnsafeMutableRawPointer(bitPattern: UInt(page.address)) else {
    return false
  }
  let words = bytes.bindMemory(to: UInt64.self, capacity: Int(pageSize / 8))
  for i in 0..<Int(pageSize / 8) { words.advanced(by: i).initialize(to: page.address ^ UInt64(i)) }
  let correct = pageMatches(UnsafePointer(words), count: Int(pageSize / 8), value: page.address)
  for i in 0..<Int(pageSize / 8) { words[i] = 0 }
  words.deinitialize(count: Int(pageSize / 8))
  return correct && givePages(&arena, address: page.address, order: 0)
    && !givePages(&arena, address: page.address, order: 0)
}

@inline(never)
private func pageMatches(_ words: UnsafePointer<UInt64>, count: Int, value: UInt64) -> Bool {
  for i in 0..<count where words[i] != value ^ UInt64(i) { return false }
  return true
}

// EDK II masks CPU interrupts before returning from ExitBootServices. Exercise
// the boot composition here without starting another CPU or programming a timer.
private func runBootCPU(_ initial: UInt64) -> Bool {
  guard cpu.start(counter: 0, frequency: 1_000_000, initialContext: initial),
    let lone = cpu.service(.poll, counter: 0), lone.next == initial, lone.sliceCounter == nil,
    let two = cpu.service(.add(context: initial + 1, qos: 3), counter: 0),
    let alarm = two.sliceCounter, alarm == 3000,
    let swap = cpu.service(.poll, counter: alarm), swap.next == initial + 1,
    let parked = cpu.service(.sleepRunning, counter: alarm), parked.next == initial,
    parked.sliceCounter == nil,
    let idle = cpu.service(.retire(context: initial), counter: alarm), idle.next == 0
  else { return false }
  return true
}
