import TarwinBoot
import TarwinBootstrap
import TarwinMM

// tarboot hands this single CPU a private stack and physical addresses, with
// interrupts masked. The loader owns the contiguous 24 KiB TBIB + map and
// pins the aperture until a display driver takes over. There are no EFI calls.
@_cdecl("tarwin_start_body")
public func kernelEntry(_ handoff: UnsafeRawPointer) -> Never {
  _ = selfTest(handoff)
  while true {}
}

@inline(never)
private func selfTest(_ block: UnsafeRawPointer) -> Bool {
  let base = UInt64(UInt(bitPattern: block))
  guard base != 0, base & 4095 == 0, base <= UInt64.max - 24576 else { return false }
  let map = UnsafeRawBufferPointer(start: block.advanced(by: 4096), count: 20480)
  guard
    let info = readHandoff(
      block: .init(start: block, count: 4096), at: base, map: map, at: base + 4096),
    info.security & 2 != 0, info.kernelPhysical != 0, info.framebuffer != 0,
    let mode = DisplayMode(
      width: info.width, height: info.height, stride: info.stride,
      format: info.format, capacity: UInt64.max),
    let fb = UnsafeMutableRawPointer(bitPattern: UInt(info.framebuffer)),
    info.framebuffer <= UInt64.max - UInt64(mode.byteCount)
  else { return false }

  // Only conventional, write-back RAM remaining after boot reservations is
  // handed to the allocator. Firmware, the stack and the image remain pinned.
  var tested = false
  #if arch(x86_64)
    let pageSize: UInt64 = 4096
  #else
    let pageSize: UInt64 = 16384
  #endif
  let wordCount = Int(pageSize / 8)
  for i in 0..<Int(info.mapCount) {
    let at = i * 32
    let flags = map.loadUnaligned(fromByteOffset: at + 16, as: UInt64.self)
    guard UInt32(truncatingIfNeeded: flags) == 0, flags >> 32 & 8 != 0 else { continue }
    let start = map.loadUnaligned(fromByteOffset: at, as: UInt64.self)
    let size = map.loadUnaligned(fromByteOffset: at + 8, as: UInt64.self)
    guard start >= info.framebuffer + UInt64(mode.byteCount) || start + size <= info.framebuffer,
      var arena = arenaFromReservation(base: start, length: size, pageSize: pageSize)
    else { continue }
    let page = takePages(&arena, order: 0)
    guard page.ok, let p = UnsafeMutableRawPointer(bitPattern: UInt(page.address)) else {
      return false
    }
    let words = p.bindMemory(to: UInt64.self, capacity: wordCount)
    for j in 0..<wordCount { words.advanced(by: j).initialize(to: page.address ^ UInt64(j)) }
    #if arch(x86_64)
      tested = matches(UnsafePointer(words), page.address, wordCount)
    #else
      tested = matches(UnsafePointer(words), page.address)
    #endif
    for j in 0..<wordCount { words[j] = 0 }
    words.deinitialize(count: wordCount)
    guard givePages(&arena, address: page.address, order: 0) else { return false }
    break
  }
  var cpu = BootCPU()
  guard tested, cpu.start(counter: 0, frequency: 1_000_000, initialContext: 1),
    cpu.service(.poll, counter: 0)?.next == 1,
    let deadline = cpu.service(.add(context: 2, qos: 3), counter: 0)?.sliceCounter,
    cpu.service(.poll, counter: deadline)?.next == 2,
    cpu.service(.sleepRunning, counter: deadline)?.next == 1,
    var debug = DebugConsole(
      mapped: .init(start: fb, count: mode.byteCount), mode: mode, debugImage: true)
  else { return false }
  return debug.write("TARWIN W0 PASS")
}

#if arch(x86_64)
@inline(never)
private func matches(_ p: UnsafePointer<UInt64>, _ address: UInt64, _ count: Int) -> Bool {
  for j in 0..<count where p[j] != address ^ UInt64(j) { return false }
  return true
}
#else
@inline(never)
private func matches(_ p: UnsafePointer<UInt64>, _ address: UInt64) -> Bool {
  for j in 0..<2048 where p[j] != address ^ UInt64(j) { return false }
  return true
}
#endif
