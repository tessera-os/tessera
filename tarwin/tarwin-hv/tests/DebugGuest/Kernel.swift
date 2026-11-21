import TarwinBoot
import TarwinBootstrap
import TarwinMM

// This separately linked debug-only guest receives a read-only launch page
// and isolated RAM from its monitor. It never uses a host pointer, host
// allocator, firmware identity, or signing key. Not the signed W1 kernel.
@_cdecl("guest_kernel_main")
public func guestKernel(_ launch: UnsafePointer<UInt64>) -> UInt64 {
  #if arch(arm64)
    let page: UInt64 = 16384
  #else
    let page: UInt64 = 4096
  #endif
  guard UInt(bitPattern: launch) == 0x180000, launch[0] == 0x3147_444b,
    launch[1] == page, launch[2] == 0x400000, launch[3] == 64 * page,
    launch[4] == 0x200000, launch[5] == 16384,
    var arena = arenaFromReservation(base: launch[2], length: launch[3], pageSize: page),
    let screen = UnsafeMutableRawPointer(bitPattern: UInt(launch[4])),
    let mode = DisplayMode(width: 144, height: 24, stride: 144, format: 1, capacity: 14336),
    var console = DebugConsole(
      mapped: .init(start: screen, count: mode.byteCount), mode: mode, debugImage: true)
  else { return 0 }
  // The tail of the console grant is a bounded serial mirror. Only the
  // guest writes; the monitor reads after guest exit. No pointer RPC.
  var count = 0
  func line(_ text: StaticString, _ console: inout DebugConsole, _ count: inout Int) -> Bool {
    guard text.utf8CodeUnitCount < 256 - count, console.write(text), console.write("\n") else {
      return false
    }
    for i in 0..<text.utf8CodeUnitCount {
      screen.storeBytes(of: text.utf8Start[i], toByteOffset: 14336 + count, as: UInt8.self)
      count += 1
    }
    screen.storeBytes(of: UInt8(10), toByteOffset: 14336 + count, as: UInt8.self)
    count += 1
    return true
  }
  guard line("TARWIN DEBUG GUEST", &console, &count) else { return 0 }
  let block = takePages(&arena, order: 1)
  guard block.ok, block.address >= launch[2], block.address - launch[2] <= launch[3] - 2 * page,
    let words = UnsafeMutablePointer<UInt64>(bitPattern: UInt(block.address))
  else { return 0 }
  let n = Int(2 * page / 8)
  for i in 0..<n { words[i] = UInt64(i) ^ block.address }
  for i in 0..<n {
    guard words[i] == UInt64(i) ^ block.address else { return 0 }
    words[i] = 0
  }
  guard givePages(&arena, address: block.address, order: 1), line("MEMORY ONLINE", &console, &count)
  else { return 0 }
  var boot = BootCPU()
  guard boot.start(counter: 0, frequency: 1_000_000, initialContext: 1),
    boot.service(.poll, counter: 0)?.next == 1,
    let deadline = boot.service(.add(context: 2, qos: 3), counter: 0)?.sliceCounter,
    boot.service(.poll, counter: deadline)?.next == 2,
    boot.service(.sleepRunning, counter: deadline)?.next == 1,
    line("BOOT CPU ONLINE", &console, &count)
  else { return 0 }
  screen.storeBytes(of: UInt64(count), toByteOffset: 16376, as: UInt64.self)
  return 0x4b44
}
